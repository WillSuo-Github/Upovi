import AppKit
import Foundation
import UpoviCore

extension AppStore {
    var bulkInstallableCount: Int { bulkItems.filter(\.canInstall).count }
    var bulkCompletedCount: Int { bulkOutcomes.values.filter { $0.status == .installed || $0.status == .current }.count }
    var bulkFailedCount: Int { bulkOutcomes.values.filter { $0.status == .failed }.count }

    func reviewAllUpdates() {
        guard !refreshing, !scanning, !checking, !installationBusy else { return }
        guard !SelfUpdateService.shared.sessionInProgress else { errorMessage = "请先完成或关闭 Upovi 自身更新。"; return }
        bulkItems = BulkUpdatePlan.make(apps: apps, results: actionableSourceResults, ignored: ignored)
        guard !bulkItems.isEmpty else { return }
        bulkOutcomes = [:]; bulkCurrentID = nil; bulkHasRun = false; bulkStopRequested = false
        bulkUpdatePresented = true
    }

    func reviewStoreUpdate(_ app: InstalledApp, candidate: UpdateCandidate) {
        guard app.isAppStore, candidate.appStoreID != nil, !installationBusy, !checking, !scanning, !refreshing,
              !SelfUpdateService.shared.sessionInProgress else { return }
        guard !ignored.contains(app.bundleID), let id = candidate.appStoreID else { return }
        do { try AppStoreUpdatePlan(application: app, storeID: id, version: candidate.version, userID: 501).validate() }
        catch { errorMessage = "此商店安装的位置或签名暂不支持 Upovi 更新，请使用原分发渠道。"; return }
        bulkItems = [.init(application: app, candidate: candidate, manualReason: nil)]
        guard !bulkItems.isEmpty else { return }
        bulkOutcomes = [:]; bulkCurrentID = nil; bulkHasRun = false; bulkStopRequested = false; bulkUpdatePresented = true
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
            if outcome.status == .current {
                sourceResults[outcome.item.id] = .init(appID: outcome.item.id, candidates: [], note: "商店确认已经最新。", status: .current,
                    checks: [.init(.appStore, .checked)], appStoreID: outcome.item.candidate.appStoreID)
            }
        }
    }

    private func installBulkItem(_ item: BulkUpdateItem) async throws {
        var stage: DiagnosticEvent.Stage = .batchPreparation
        do {
            try Task.checkCancellation()
            guard !bulkPersistenceFailed else { throw PeerError.unavailable("Batch history could not be saved; installation was not started") }
            guard networkAvailable else { throw URLError(.notConnectedToInternet) }
            let app = item.application, candidate = item.candidate
            installationProgress = "\(app.name)：正在下载并验证…"; canCancelInstallation = true
            let progress: @Sendable (Int64, Int64) -> Void = { [weak self] received, expected in
                Task { @MainActor in
                    guard let self, self.bulkCurrentID == item.id, self.canCancelInstallation else { return }
                    self.installationProgress = expected > 0 ? "\(app.name)：下载中 \(received * 100 / expected)%" : "\(app.name)：已下载 \(received / 1_000_000) MB"
                }
            }
            if app.isAppStore {
                try Task.checkCancellation()
                guard saveBulkPhase(item.id, phase: .installing, detail: "等待商店下载和管理员认证") else { throw PeerError.unavailable("Batch history could not be saved") }
                canCancelInstallation = false; stage = .batchInstallation
                installationProgress = "\(app.name)：等待 Apple 商店服务完成更新，可能需要账户或管理员认证…"
                try await installStoreUpdate(candidate, app)
            } else if candidate.download?.url.pathExtension.lowercased() == "pkg" {
                let package = try await administrator.preparePackage(candidate, app: app, progress: progress)
                defer { administrator.discard(package) }
                try Task.checkCancellation()
                guard saveBulkPhase(item.id, phase: .installing, detail: "等待管理员安装") else { throw PeerError.unavailable("Batch history could not be saved") }
                canCancelInstallation = false; stage = .batchInstallation
                installationProgress = "\(app.name)：等待管理员授权并安装…"
                try await administrator.perform(package.plan)
            } else {
                let prepared = try await installer.prepare(app: app, candidate: candidate, progress: progress)
                do {
                    try Task.checkCancellation()
                    guard saveBulkPhase(item.id, phase: .installing, detail: "正在安装") else { throw PeerError.unavailable("Batch history could not be saved") }
                    canCancelInstallation = false; stage = .batchInstallation
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
        } catch {
            if !(error is AppStoreAlreadyCurrent) { recordDiagnostic(stage, appID: item.application.id, error: error) }
            throw error
        }
    }
}
