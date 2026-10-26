import AppKit
import Foundation
import UpoviCore

extension AppStore {
    var bulkInstallableCount: Int { bulkItems.filter(\.canInstall).count }
    var bulkCompletedCount: Int { bulkOutcomes.values.filter { $0.status == .installed }.count }
    var bulkFailedCount: Int { bulkOutcomes.values.filter { $0.status == .failed }.count }

    func reviewAllUpdates() {
        guard !refreshing, !scanning, !checking, !installationBusy else { return }
        guard !SelfUpdateService.shared.sessionInProgress else { errorMessage = "请先完成或关闭 Upovi 自身更新。"; return }
        bulkItems = BulkUpdatePlan.make(apps: apps, results: actionableSourceResults, ignored: ignored)
        guard !bulkItems.isEmpty else { return }
        bulkOutcomes = [:]; bulkCurrentID = nil; bulkHasRun = false; bulkStopRequested = false
        bulkUpdatePresented = true
    }

    func startAllUpdates() {
        guard bulkUpdatePresented, !bulkHasRun, !installing, !checking, !scanning, !refreshing,
              bulkInstallableCount > 0, !SelfUpdateService.shared.sessionInProgress else { return }
        guard networkAvailable else { errorMessage = "当前没有可用网络，请联网后再开始更新。"; return }
        let record = BulkUpdateRecord(items: bulkItems)
        let previous = batchHistory
        batchHistory.insert(record, at: 0); batchHistory = Array(batchHistory.prefix(10))
        guard saveBatchHistory() else { batchHistory = previous; return }
        bulkRecordID = record.id; bulkPersistenceFailed = false
        bulkHasRun = true; bulkUpdating = true; installing = true; bulkStopRequested = false
        let items = bulkItems
        bulkTask = Task { [self] in
            _ = await BulkUpdateRunner.run(items, shouldStop: { await self.bulkStopRequested },
                operation: { try await self.installBulkItem($0) }, report: { await self.recordBulkEvent($0) })
            canCancelInstallation = false; bulkCurrentID = nil
            await refreshInstallations()
            apps = await scanInventory()
            if let index = batchHistory.firstIndex(where: { $0.id == bulkRecordID }) {
                batchHistory[index].finishedAt = Date(); saveBatchHistory()
            }
            installationProgress = "全部更新结束：\(bulkCompletedCount) 个完成，\(bulkFailedCount) 个失败"
            installing = false; bulkUpdating = false
            if networkEnabled { p2pBatchOffset = 0; restartP2P() }
        }
    }

    func stopAllUpdates() {
        guard bulkUpdating else { return }
        bulkStopRequested = true
        if canCancelInstallation { bulkTask?.cancel() }
    }

    private func recordBulkEvent(_ event: BulkUpdateEvent) {
        switch event {
        case .started(let item):
            bulkCurrentID = item.id
            saveBulkPhase(item.id, phase: .preparing, detail: "正在下载并验证")
        case .finished(let outcome):
            bulkOutcomes[outcome.item.id] = outcome
            saveBulkPhase(outcome.item.id, phase: .init(rawValue: outcome.status.rawValue) ?? .failed, detail: outcome.detail)
            if outcome.status == .installed { sourceResults[outcome.item.id] = nil }
        }
    }

    private func installBulkItem(_ item: BulkUpdateItem) async throws {
        try Task.checkCancellation()
        guard !bulkPersistenceFailed else { throw PeerError.unavailable("Batch history could not be saved; installation was not started") }
        guard networkAvailable else { throw PeerError.unavailable("Network unavailable; application was not updated") }
        let app = item.application, candidate = item.candidate
        installationProgress = "\(app.name)：正在下载并验证…"; canCancelInstallation = true
        let progress: @Sendable (Int64, Int64) -> Void = { [weak self] received, expected in
            Task { @MainActor in
                guard let self, self.bulkCurrentID == item.id, self.canCancelInstallation else { return }
                self.installationProgress = expected > 0 ? "\(app.name)：下载中 \(received * 100 / expected)%" : "\(app.name)：已下载 \(received / 1_000_000) MB"
            }
        }
        if candidate.download?.url.pathExtension.lowercased() == "pkg" {
            let package = try await administrator.preparePackage(candidate, app: app, progress: progress)
            defer { administrator.discard(package) }
            try Task.checkCancellation()
            guard saveBulkPhase(item.id, phase: .installing, detail: "等待管理员安装") else { throw PeerError.unavailable("Batch history could not be saved") }
            canCancelInstallation = false
            installationProgress = "\(app.name)：等待管理员授权并安装…"
            try await administrator.perform(package.plan)
        } else {
            let prepared = try await installer.prepare(app: app, candidate: candidate, progress: progress)
            do {
                try Task.checkCancellation()
                guard saveBulkPhase(item.id, phase: .installing, detail: "正在安装") else { throw PeerError.unavailable("Batch history could not be saved") }
                canCancelInstallation = false
                if !FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: app.path).deletingLastPathComponent().path) {
                    installationProgress = "\(app.name)：等待管理员授权并安装…"
                    try await administrator.perform(.init(operation: .application, application: app,
                        version: prepared.replacement.version, build: prepared.replacement.build,
                        artifactPath: prepared.bundle.resolvingSymlinksInPath().path))
                } else {
                    installationProgress = "\(app.name)：正在关闭应用并安装…"
                    _ = try await installer.install(prepared.id)
                }
                await installer.discard(prepared.id)
            } catch { await installer.discard(prepared.id); throw error }
        }
    }
}
