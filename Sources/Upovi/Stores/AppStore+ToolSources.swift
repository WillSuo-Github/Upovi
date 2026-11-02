import Foundation
import UpoviCore

extension AppStore {
    var availableToolSources: [ToolSource] { ToolSource.allCases.filter { enabledToolSources.contains($0) && toolLocations[$0] != nil } }
    var pendingToolUpdates: [ToolUpdateItem] {
        availableToolSources.flatMap { source -> [ToolUpdateItem] in
            guard toolCheckErrors[source] == nil, let snapshot = toolSnapshots[source] else { return [] }
            return snapshot.updates.map { .init(source: source, package: $0, context: snapshot.context) }
        }.sorted { $0.package.name.localizedStandardCompare($1.package.name) == .orderedAscending }
    }
    var toolUpdateCount: Int { pendingToolUpdates.count }
    var toolFailedItems: [ToolUpdateItem] {
        toolBatchItems.filter { toolOutcomes[$0.id]?.state == .failed || toolOutcomes[$0.id]?.state == .interrupted }
    }
    var visibleToolUpdates: [ToolUpdateItem] {
        guard bulkSummaryVisible else { return pendingToolUpdates }
        let ids = Set(toolBatchItems.map(\.id))
        return toolBatchItems.filter { toolOutcomes[$0.id]?.state != .succeeded } + pendingToolUpdates.filter { !ids.contains($0.id) }
    }
    func matchesSearch(_ item: ToolUpdateItem) -> Bool {
        search.isEmpty || (item.package.name + " " + item.source.title).localizedCaseInsensitiveContains(search)
    }

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
    func reviewToolUpdates(_ items: [ToolUpdateItem]) {
        guard !operationBusy, !SelfUpdateService.shared.sessionInProgress else { return }
        toolBatchItems = items.filter { enabledToolSources.contains($0.source) && toolLocations[$0.source] != nil }
        guard !toolBatchItems.isEmpty else { return }
        clearBulkTransfers()
        bulkItems = []; bulkOutcomes = [:]; toolOutcomes = [:]; bulkHasRun = false
        bulkStopRequested = false; bulkSummaryVisible = false; bulkUpdatePresented = true
    }

    func runToolBatch() async {
        for item in toolBatchItems {
            let source = item.source
            var record = ToolUpdateRecord(source: source, item: item)
            if bulkStopRequested {
                record.state = .interrupted; record.detail = String(localized: "已停止后续任务，此工具未执行。")
                record.finishedAt = Date(); toolOutcomes[item.id] = record
                continue
            }
            guard enabledToolSources.contains(source), let executable = toolLocations[source] else {
                record.state = .failed; record.detail = String(localized: "此工具来源已关闭或不再可用。")
                record.finishedAt = Date(); toolOutcomes[item.id] = record; continue
            }
            toolHistory.insert(record, at: 0); toolHistory = Array(toolHistory.prefix(500))
            guard saveToolHistory() else {
                record.state = .failed; record.detail = String(localized: "无法保存更新记录，未执行工具更新。")
                record.finishedAt = Date()
                if let index = toolHistory.firstIndex(where: { $0.id == record.id }) { toolHistory[index] = record }
                toolOutcomes[item.id] = record; bulkStopRequested = true; continue
            }
            toolRunningID = item.id
            do {
                let result = try await updateToolPackage(item, executable)
                toolSnapshots[source] = result; toolCheckErrors[source] = nil
                record.state = .succeeded
                record.detail = item.package.name + ": " + item.package.installed + " → " + (result.installed[item.package.name] ?? item.package.available)
            } catch {
                record.state = .failed; record.detail = ToolSourceService.sanitized(error.localizedDescription)
                // A package failure is local to this row, not a failed inventory for every sibling.
            }
            record.finishedAt = Date(); toolOutcomes[item.id] = record
            if let index = toolHistory.firstIndex(where: { $0.id == record.id }) { toolHistory[index] = record }
            if !saveToolHistory() { bulkStopRequested = true }
            toolRunningID = nil
        }
    }
    @discardableResult func saveToolHistory() -> Bool {
        guard let data = try? JSONEncoder().encode(toolHistory) else { return false }
        return preferences.set(data, forKey: "toolHistoryV1")
    }
    func retryLatestBulkRun() {
        let items = toolFailedItems
        if let record = batchHistory.first(where: { $0.id == bulkRecordID }), !record.retryIDs.isEmpty {
            retryBatch(record, toolItems: items)
        } else { reviewToolUpdates(items) }
    }
}
