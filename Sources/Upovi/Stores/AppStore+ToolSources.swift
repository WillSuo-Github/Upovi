import Foundation
import UpoviCore

extension AppStore {
    var availableToolSources: [ToolSource] { ToolSource.allCases.filter { enabledToolSources.contains($0) && toolLocations[$0] != nil } }
    var toolUpdateCount: Int { availableToolSources.reduce(0) { $0 + (toolSnapshots[$1]?.updates.count ?? 0) } }
    var toolFailedSources: [ToolSource] { toolBatchSources.filter { toolOutcomes[$0]?.state == .failed || toolOutcomes[$0]?.state == .interrupted } }

    func setToolSource(_ source: ToolSource, enabled: Bool) {
        guard !installationBusy else { return }
        var next = enabledToolSources
        if enabled { next.insert(source) } else { next.remove(source) }
        guard preferences.set(next.map(\.rawValue).sorted(), forKey: "toolSourcesV1") else { return }
        enabledToolSources = next
        toolSnapshots[source] = nil; toolCheckErrors[source] = nil
        refreshToolSources()
    }
    func rediscoverToolSources() {
        guard !installationBusy else { return }
        toolLocations = ToolSourceDiscovery.locations()
        refreshToolSources()
    }
    func refreshToolSources() {
        guard !installationBusy else { return }
        toolCheckTask?.cancel()
        let selected = availableToolSources, locations = toolLocations, checker = checkToolSource
        toolChecking = !selected.isEmpty
        toolCheckTask = Task {
            for source in selected {
                guard !Task.isCancelled, let executable = locations[source] else { break }
                do {
                    let snapshot = try await checker(source, executable)
                    guard !Task.isCancelled, enabledToolSources.contains(source) else { return }
                    toolSnapshots[source] = snapshot; toolCheckErrors[source] = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    toolCheckErrors[source] = ToolSourceService.sanitized(error.localizedDescription)
                }
            }
            if !Task.isCancelled { toolChecking = false }
        }
    }
    func reviewToolUpdates(_ sources: [ToolSource]) {
        guard !installationBusy, !refreshing, !checking, !scanning, !toolChecking else { return }
        toolBatchSources = sources.filter { enabledToolSources.contains($0) && toolLocations[$0] != nil }
        guard !toolBatchSources.isEmpty else { return }
        bulkItems = []; bulkOutcomes = [:]; toolOutcomes = [:]; bulkHasRun = false
        bulkStopRequested = false; bulkSummaryVisible = false; bulkUpdatePresented = true
    }

    func runToolBatch() async {
        for source in toolBatchSources {
            var record = ToolUpdateRecord(source: source)
            if bulkStopRequested {
                record.state = .interrupted; record.detail = String(localized: "已停止后续任务，此来源未执行。")
                record.finishedAt = Date(); toolOutcomes[source] = record
                continue
            }
            guard enabledToolSources.contains(source), let executable = toolLocations[source] else {
                record.state = .failed; record.detail = String(localized: "此工具来源已关闭或不再可用。")
                record.finishedAt = Date(); toolOutcomes[source] = record; continue
            }
            toolHistory.insert(record, at: 0); toolHistory = Array(toolHistory.prefix(100))
            guard saveToolHistory() else {
                record.state = .failed; record.detail = String(localized: "无法保存更新记录，未执行工具更新。")
                record.finishedAt = Date()
                if let index = toolHistory.firstIndex(where: { $0.id == record.id }) { toolHistory[index] = record }
                toolOutcomes[source] = record; bulkStopRequested = true; continue
            }
            toolRunningSource = source
            let before = toolSnapshots[source]
            do {
                let result = try await updateToolSource(source, executable, before?.context)
                toolSnapshots[source] = result; toolCheckErrors[source] = nil
                record.state = .succeeded
                let changes = result.installed.sorted { $0.key < $1.key }.compactMap { name, version -> String? in
                    guard let old = before?.installed[name], old != version else { return nil }
                    return name + ": " + old + " → " + version
                }
                record.detail = changes.isEmpty ? String(localized: "包管理器已完成更新，并重新核对已安装的全局工具。") : changes.joined(separator: "\n")
            } catch {
                record.state = .failed; record.detail = ToolSourceService.sanitized(error.localizedDescription)
                toolCheckErrors[source] = record.detail
            }
            record.finishedAt = Date(); toolOutcomes[source] = record
            if let index = toolHistory.firstIndex(where: { $0.id == record.id }) { toolHistory[index] = record }
            if !saveToolHistory() { bulkStopRequested = true }
            toolRunningSource = nil
        }
    }
    @discardableResult func saveToolHistory() -> Bool {
        guard let data = try? JSONEncoder().encode(toolHistory) else { return false }
        return preferences.set(data, forKey: "toolHistoryV1")
    }
    func retryLatestBulkRun() {
        let sources = toolFailedSources
        if let record = batchHistory.first(where: { $0.id == bulkRecordID }), !record.retryIDs.isEmpty {
            retryBatch(record, toolSources: sources)
        } else { reviewToolUpdates(sources) }
    }
}
