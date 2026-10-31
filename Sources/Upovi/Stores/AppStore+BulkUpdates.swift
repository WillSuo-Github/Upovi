import AppKit
import Foundation
import UpoviCore

extension AppStore {
    var bulkAppInstallableCount: Int { bulkItems.filter(\.canInstall).count }
    var bulkInstallableCount: Int { bulkAppInstallableCount + toolBatchSources.count }
    var bulkCompletedCount: Int { bulkOutcomes.values.filter { $0.status == .installed || $0.status == .current }.count + toolOutcomes.values.filter { $0.state == .succeeded }.count }
    var bulkFailedCount: Int { bulkOutcomes.values.filter { $0.status == .failed }.count + toolOutcomes.values.filter { $0.state == .failed }.count }
    var bulkFinishedCount: Int { bulkOutcomes.values.filter { $0.status != .manual }.count + toolOutcomes.count }
    var bulkDownloadingCount: Int { bulkActiveIDs.filter { transfers[$0]?.phase == .downloading }.count }

    /// Average of every installable item's own progress, so the overall bar moves with each download.
    var bulkOverallFraction: Double {
        let items = bulkItems.filter(\.canInstall)
        guard bulkInstallableCount > 0 else { return 0 }
        let total = items.reduce(0.0) { sum, item in
            sum + (bulkOutcomes[item.id] != nil ? 1 : transfers[item.id]?.fraction ?? 0)
        }
        return (total + Double(toolOutcomes.count)) / Double(bulkInstallableCount)
    }

    func reviewAllUpdates() {
        guard !refreshing, !scanning, !checking, !toolChecking, !installationBusy else { return }
        guard !SelfUpdateService.shared.sessionInProgress else { errorMessage = String(localized: "请先完成或关闭 Upovi 自身更新。"); return }
        bulkItems = BulkUpdatePlan.make(apps: apps, results: actionableSourceResults, ignored: ignored)
        toolBatchSources = availableToolSources
        guard !bulkItems.isEmpty || !toolBatchSources.isEmpty else { return }
        resetBulkRun()
        bulkUpdatePresented = true
    }

    func reviewStoreUpdate(_ app: InstalledApp, candidate: UpdateCandidate) {
        guard app.isAppStore, candidate.appStoreID != nil, !installationBusy, !checking, !scanning, !refreshing,
              !SelfUpdateService.shared.sessionInProgress else { return }
        guard !ignored.contains(app.bundleID), let id = candidate.appStoreID else { return }
        do { try AppStoreUpdatePlan(application: app, storeID: id, version: candidate.version, userID: 501).validate() }
        catch { errorMessage = String(localized: "此商店安装的位置或签名暂不支持 Upovi 更新，请使用原分发渠道。"); return }
        bulkItems = [.init(application: app, candidate: candidate, manualReason: nil)]
        toolBatchSources = []
        resetBulkRun()
        bulkUpdatePresented = true
    }

    private func resetBulkRun() {
        cancelBulkApplicationQuit()
        clearBulkTransfers()
        bulkOutcomes = [:]; toolOutcomes = [:]; bulkActiveIDs = []; bulkHasRun = false; bulkStopRequested = false; bulkSummaryVisible = false
    }

    func clearBulkTransfers() {
        for item in bulkItems { transfers[item.id] = nil }
        transferSamples = [:]
    }

    /// Hides the finished batch dashboard and returns the Updates page to its normal list.
    func dismissBulkSummary() {
        guard !bulkUpdating else { return }
        clearBulkTransfers()
        bulkSummaryVisible = false
    }

    func startAllUpdates() {
        guard canStartBulkUpdates else { return }
        let running = runningUpdateApplications(bulkItems.filter(\.canInstall).map(\.application))
        if !running.isEmpty {
            bulkQuitApplications = running
            bulkQuitPresented = true
            return
        }
        beginAllUpdates(applicationsToQuit: [])
    }

    func confirmBulkApplicationQuit() {
        let applications = bulkQuitApplications
        cancelBulkApplicationQuit()
        beginAllUpdates(applicationsToQuit: applications)
    }

    func cancelBulkApplicationQuit() {
        bulkQuitPresented = false
        bulkQuitApplications = []
    }

    private var canStartBulkUpdates: Bool {
        bulkUpdatePresented && !bulkHasRun && !installing && !checking && !toolChecking && !scanning && !refreshing
            && bulkInstallableCount > 0 && !SelfUpdateService.shared.sessionInProgress
    }

    private func beginAllUpdates(applicationsToQuit: [InstalledApp]) {
        guard canStartBulkUpdates else { return }
        guard networkAvailable else { errorMessage = String(localized: "当前没有可用网络，请联网后再开始更新。"); return }
        if !bulkItems.isEmpty {
            let record = BulkUpdateRecord(items: bulkItems)
            let previous = batchHistory
            batchHistory.insert(record, at: 0); batchHistory = Array(batchHistory.prefix(10))
            guard saveBatchHistory() else { batchHistory = previous; return }
            bulkRecordID = record.id
        } else { bulkRecordID = nil }
        bulkPersistenceFailed = false
        bulkHasRun = true; bulkUpdating = true; installing = true; bulkStopRequested = false
        for item in bulkItems where item.canInstall { transfers[item.id] = TransferProgress() }
        // Progress now lives on the Updates page rows instead of the confirmation sheet.
        bulkSummaryVisible = true; bulkUpdatePresented = false; section = .updates
        let items = bulkItems, width = bulkConcurrency
        bulkTask = Task { [self] in
            var failedToQuit = Set<String>()
            for app in applicationsToQuit {
                if bulkStopRequested { break }
                do { try await cancellable(app.id) { [self] in try await quitUpdateApplication(app) } }
                catch is CancellationError { bulkStopRequested = true; break }
                catch {
                    failedToQuit.insert(app.id)
                    recordDiagnostic(.batchPreparation, appID: app.id, error: error)
                    if let item = items.first(where: { $0.id == app.id }) {
                        recordBulkEvent(.finished(.init(item: item, status: .failed, detail: error.localizedDescription)))
                    }
                }
            }
            let authorization = makeInstallationAuthorizationBatch()
            _ = await BulkUpdateRunner.run(items.filter { !failedToQuit.contains($0.id) }, concurrency: width, shouldStop: { await self.bulkStopRequested },
                operation: { try await self.installBulkItem($0, authorization: authorization) }, report: { event in
                    await self.recordBulkPreparationEvent(event, authorization: authorization)
                })
            await installAuthorizedBulkItems(authorization)
            await runToolBatch()
            bulkActiveIDs = []; bulkCancellers = [:]
            await refreshInstallations()
            apps = await scanInventory()
            if let index = batchHistory.firstIndex(where: { $0.id == bulkRecordID }) {
                batchHistory[index].finishedAt = Date(); saveBatchHistory()
            }
            installationProgress = String(localized: "全部更新结束：\(bulkCompletedCount) 个完成，\(bulkFailedCount) 个失败")
            installing = false; bulkUpdating = false
            if networkEnabled { p2pBatchOffset = 0; restartP2P() }
        }
    }

    private func recordBulkPreparationEvent(_ event: BulkUpdateEvent, authorization: InstallationAuthorizationBatch) {
        // A successfully prepared privileged job is still pending, not an installed application.
        if case .finished(let outcome) = event, outcome.status == .installed, authorization.contains(outcome.item.id) { return }
        recordBulkEvent(event)
    }

    private func installAuthorizedBulkItems(_ batch: InstallationAuthorizationBatch) async {
        guard !batch.jobs.isEmpty else { return }
        bulkCancellers["authorizationBatch"] = { batch.stop() }
        defer { bulkCancellers["authorizationBatch"] = nil }
        if bulkStopRequested { batch.stop() }
        await withTaskGroup(of: Void.self) { group in
            for job in batch.jobs {
                group.addTask { await self.installAuthorizedBulkJob(job, batch: batch) }
            }
        }
    }

    private func installAuthorizedBulkJob(_ job: InstallationAuthorizationBatch.Job, batch: InstallationAuthorizationBatch) async {
        defer { batch.finishRegistration(job.item.id) }
        _ = await BulkUpdateRunner.run([job.item], shouldStop: { await self.bulkStopRequested }, operation: { _ in
            do {
                guard await !self.bulkPersistenceFailed else { throw PeerError.unavailable("Batch history could not be saved; installation was not started") }
                try await job.operation(batch.authorization(for: job.item.id))
            } catch {
                if !(error is AppStoreAlreadyCurrent) && !(error is ApplicationAlreadyCurrent) { await self.recordDiagnostic(.batchInstallation, appID: job.item.id, error: error) }
                throw error
            }
        }, report: { event in
            if case .finished = event { await self.recordBulkEvent(event) }
        })
        await job.cleanup()
    }

    /// Stops queued applications and cancels running downloads; installations already committing finish.
    func stopAllUpdates() {
        guard bulkUpdating else { return }
        bulkStopRequested = true
        for cancel in bulkCancellers.values { cancel() }
    }

    private func recordBulkEvent(_ event: BulkUpdateEvent) {
        switch event {
        case .started(let item):
            bulkActiveIDs.insert(item.id)
            beginTransfer(item.id)
            saveBulkPhase(item.id, phase: .preparing, detail: String(localized: "正在下载并验证"))
        case .finished(let outcome):
            let id = outcome.item.id
            bulkActiveIDs.remove(id)
            bulkOutcomes[id] = outcome
            if outcome.status != .manual {
                let phase: TransferProgress.Phase = switch outcome.status {
                    case .installed, .current: .installed
                    case .cancelled: .cancelled
                    default: .failed
                }
                transfers[id, default: TransferProgress()].finish(phase)
            }
            saveBulkPhase(id, phase: .init(rawValue: outcome.status.rawValue) ?? .failed, detail: outcome.detail)
            if outcome.status == .installed { sourceResults[id] = nil }
            if outcome.status == .current {
                sourceResults[id] = .init(appID: id, candidates: [], note: outcome.detail, status: .current,
                    checks: outcome.item.application.isAppStore ? [.init(.appStore, .checked)] : [], appStoreID: outcome.item.candidate.appStoreID)
            }
        }
    }

    func beginTransfer(_ id: String, at now: Date = Date()) {
        transfers[id] = TransferProgress(phase: .downloading)
        transferSamples[id] = .init(startedAt: now)
    }

    /// Publish at most twice a second, except for phase changes and the final byte count.
    func reportDownload(_ id: String, received: Int64, expected: Int64, at now: Date = Date()) {
        guard var value = transfers[id], [.downloading, .verifying].contains(value.phase) else { return }
        var sample = transferSamples[id] ?? .init(startedAt: now)
        let sampled = sample.record(received, at: now)
        transferSamples[id] = sample
        let phase: TransferProgress.Phase = expected > 0 && received >= expected ? .verifying : .downloading
        guard sampled || phase != value.phase || expected != value.expected else { return }
        value.received = received; value.expected = expected; value.phase = phase
        value.bytesPerSecond = sample.bytesPerSecond; value.sampleTime = now
        transfers[id] = value
    }

    func setTransferPhase(_ id: String, _ phase: TransferProgress.Phase) {
        transfers[id]?.phase = phase
    }

    /// Runs a download in its own task so stopping the batch cancels it without cancelling sibling applications.
    private func cancellable<T: Sendable>(_ id: String, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let task = Task { @MainActor in try await work() }
        bulkCancellers[id] = { task.cancel() }
        defer { bulkCancellers[id] = nil }
        if bulkStopRequested { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func installBulkItem(_ item: BulkUpdateItem, authorization: InstallationAuthorizationBatch) async throws {
        var stage: DiagnosticEvent.Stage = .batchPreparation
        do {
            try Task.checkCancellation()
            guard !bulkPersistenceFailed else { throw PeerError.unavailable("Batch history could not be saved; installation was not started") }
            guard networkAvailable else { throw URLError(.notConnectedToInternet) }
            let app = item.application, candidate = item.candidate, id = item.id
            if try BundleVerifier.selectedUpdateIsInstalled(app, candidate: candidate) { throw ApplicationAlreadyCurrent() }
            let progress: @Sendable (Int64, Int64) -> Void = { [weak self] received, expected in
                Task { @MainActor in self?.reportDownload(id, received: received, expected: expected) }
            }
            if app.isAppStore {
                try Task.checkCancellation()
                guard saveBulkPhase(id, phase: .installing, detail: candidate.storeReceiptRecovery == nil ? String(localized: "等待商店下载和管理员认证") : String(localized: "正在完成商店安装收尾")) else { throw PeerError.unavailable("Batch history could not be saved") }
                stage = .batchInstallation
                setTransferPhase(id, .waitingForAuthorization)
                authorization.enqueue(item) { [self] authorize in
                    setTransferPhase(id, .installing)
                    try await installStoreUpdate(candidate, app, authorize)
                }
            } else if candidate.download?.url.pathExtension.lowercased() == "pkg" {
                let package = try await cancellable(id) { [self] in try await administrator.preparePackage(candidate, app: app, progress: progress) }
                do {
                    if bulkStopRequested { throw CancellationError() }
                    guard saveBulkPhase(id, phase: .installing, detail: String(localized: "等待管理员安装")) else { throw PeerError.unavailable("Batch history could not be saved") }
                    setTransferPhase(id, .waitingForAuthorization)
                    authorization.enqueue(item, cleanup: { [self] in administrator.discard(package) }) { [self] authorize in
                        setTransferPhase(id, .installing)
                        try await administrator.perform(package.plan, authorize: authorize)
                    }
                } catch { administrator.discard(package); throw error }
            } else {
                let prepared = try await cancellable(id) { [self] in try await installer.prepare(app: app, candidate: candidate, progress: progress) }
                do {
                    if bulkStopRequested { throw CancellationError() }
                    guard saveBulkPhase(id, phase: .installing, detail: String(localized: "正在安装")) else { throw PeerError.unavailable("Batch history could not be saved") }
                    stage = .batchInstallation
                    if !FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: app.path).deletingLastPathComponent().path) {
                        let plan = AdministratorInstallPlan(operation: .application, application: app,
                            version: prepared.replacement.version, build: prepared.replacement.build,
                            artifactPath: prepared.bundle.resolvingSymlinksInPath().path)
                        setTransferPhase(id, .waitingForAuthorization)
                        authorization.enqueue(item, cleanup: { [self] in await installer.discard(prepared.id) }) { [self] authorize in
                            setTransferPhase(id, .installing)
                            try await administrator.perform(plan, authorize: authorize)
                        }
                    } else {
                        setTransferPhase(id, .installing)
                        _ = try await installer.install(prepared.id)
                    }
                    if !authorization.contains(id) { await installer.discard(prepared.id) }
                } catch { await installer.discard(prepared.id); throw error }
            }
        } catch {
            if error is InstalledApplicationChanged,
               (try? BundleVerifier.selectedUpdateIsInstalled(item.application, candidate: item.candidate)) == true { throw ApplicationAlreadyCurrent() }
            if !(error is AppStoreAlreadyCurrent) && !(error is ApplicationAlreadyCurrent) { recordDiagnostic(stage, appID: item.application.id, error: error) }
            throw error
        }
    }
}
