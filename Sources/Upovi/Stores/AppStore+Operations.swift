import AppKit
import Foundation
import Network
import UpoviCore

extension AppStore {
    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await refreshInstallations()
            while !Task.isCancelled {
                policyClock = Date()
                if CheckSchedule.isDue(enabled: automaticChecks && !apps.isEmpty, online: networkAvailable,
                    busy: refreshing || scanning || checking || installationBusy, lastAttempt: lastCheckAttempt,
                    intervalMinutes: checkIntervalMinutes) { beginChecking() }
                if networkEnabled && !syncing && !scanning && !refreshing && !installationBusy &&
                    (lastSyncAttempt.map { Date().timeIntervalSince($0) >= 600 } ?? true) { beginSync() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.wiredEthernet))-\(path.usesInterfaceType(.cellular))"
            Task { @MainActor in
                guard let self else { return }
                defer { self.previousPath = signature }
                let reconnected = !self.networkAvailable && path.status == .satisfied
                self.networkAvailable = path.status == .satisfied
                self.downloadCenter.networkChanged(self.networkAvailable)
                if reconnected { self.lastCheckAttempt = nil }
                if self.previousPath != nil && self.previousPath != signature { self.recoverNetwork(reason: "path-change") }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.upovi.path"))
    }
    func recoverNetwork(reason: String = "network-change") {
        // Source scheduling recovers independently of whether optional P2P is enabled.
        if reason == "wake" { lastCheckAttempt = nil }
        guard networkEnabled else { return }
        logger.info("network recovery requested reason=\(reason, privacy: .public)")
        networkStatus = String(localized: "网络已变化，正在重新连接…")
        restartP2P()
    }
    func setNotifications(_ enabled: Bool) async {
        let granted = enabled ? await notifications.requestAccess() : false
        notificationsEnabled = granted
        preferences.set(granted, forKey: "notificationsV1")
        if enabled && !granted { errorMessage = String(localized: "通知权限未开启，可在系统设置中允许 Upovi 通知。") }
    }
    func configureSource(for app: InstalledApp, feed: String, repository: String) throws {
        let feed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = feed.isEmpty ? nil : URL(string: feed)
        guard feed.isEmpty || (url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil),
              repository.isEmpty || GitHubRelease.validRepository(repository) else { throw PeerError.invalid("Use an HTTPS appcast URL and a GitHub owner/repository") }
        sourceOverrides[app.bundleID] = .init(appcast: url, githubRepository: repository.isEmpty ? nil : repository)
        let data = try JSONEncoder().encode(sourceOverrides)
        preferences.set(data, forKey: "sourceOverridesV1")
        sourceResults[app.id] = nil
    }
    func prepareInstallation(_ candidate: UpdateCandidate, app: InstalledApp) {
        guard !installationBusy, !refreshing, !checking, !scanning else { return }
        guard !SelfUpdateService.shared.sessionInProgress else { errorMessage = String(localized: "请先完成或关闭 Upovi 自身更新，再安装其他应用。"); return }
        installing = true; canCancelInstallation = true; installationProgress = String(localized: "正在下载并验证更新…")
        let id = app.id
        beginTransfer(id)
        let progress: @Sendable (Int64, Int64) -> Void = { [weak self] received, expected in
            Task { @MainActor in self?.reportDownload(id, received: received, expected: expected) }
        }
        installationTask = Task { [self] in
            defer { installing = false; canCancelInstallation = false }
            do {
                if candidate.download?.url.pathExtension.lowercased() == "pkg" {
                    preparedPackage = try await administrator.preparePackage(candidate, app: app, progress: progress)
                    setTransferPhase(id, .awaitingConfirmation)
                    installationConfirmation = true; installationProgress = String(localized: "安装包已验证，等待管理员安装确认")
                    return
                }
                let value = try await installer.prepare(app: app, candidate: candidate, progress: progress)
                setTransferPhase(id, .awaitingConfirmation)
                preparedUpdate = value
                administratorInstallRequested = !FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: app.path).deletingLastPathComponent().path)
                installationConfirmation = true; installationProgress = String(localized: "更新已验证，等待安装确认")
            } catch { transfers[id] = nil; recordDiagnostic(.preparation, appID: app.id, error: error); installationProgress = String(localized: "下载或验证未完成"); if !Task.isCancelled && !(error is CancellationError) { errorMessage = error.localizedDescription } }
        }
    }
    func cancelInstallation() { installationTask?.cancel() }
    func discardInstallation() {
        for id in [preparedUpdate?.application.id, preparedPackage?.plan.application.id].compactMap({ $0 }) { transfers[id] = nil }
        if let value = preparedUpdate { Task { await installer.discard(value.id) } }
        if let value = preparedPackage { administrator.discard(value); preparedPackage = nil }
        preparedUpdate = nil; installationConfirmation = false; installationProgress = ""
    }
    func confirmInstallation() {
        if let package = preparedPackage {
            confirmAdministratorInstallation(package.plan)
            return
        }
        guard let value = preparedUpdate, !installing else { return }
        if administratorInstallRequested {
            confirmAdministratorInstallation(.init(operation: .application, application: value.application,
                version: value.replacement.version, build: value.replacement.build,
                artifactPath: value.bundle.resolvingSymlinksInPath().path))
            return
        }
        installationConfirmation = false; installing = true; canCancelInstallation = false; installationProgress = String(localized: "正在安装，旧版本将保留为备份…")
        setTransferPhase(value.application.id, .installing)
        installationTask = Task { [self] in
            defer { installing = false; preparedUpdate = nil; transfers[value.application.id] = nil }
            do {
                _ = try await installer.install(value.id)
                installationProgress = String(localized: "安装完成，可在安装记录中恢复旧版本")
                await refreshInstallations()
                let found = await scanInventory()
                apps = found; sourceResults[value.application.id] = nil
                logger.info("installation completed")
            } catch { recordDiagnostic(.installation, appID: value.application.id, error: error); errorMessage = error.localizedDescription; installationProgress = String(localized: "安装未完成，原应用或恢复备份已保留") }
        }
    }
    private func confirmAdministratorInstallation(_ plan: AdministratorInstallPlan) {
        guard !installing, !SelfUpdateService.shared.sessionInProgress else { return }
        installationConfirmation = false; installing = true; canCancelInstallation = false
        installationProgress = String(localized: "正在请求管理员授权并安装，请留意系统授权窗口…")
        setTransferPhase(plan.application.id, .waitingForAuthorization)
        installationTask = Task { [self] in
            defer {
                installing = false; transfers[plan.application.id] = nil
                if let value = preparedUpdate { Task { await installer.discard(value.id) } }
                if let value = preparedPackage { administrator.discard(value) }
                preparedUpdate = nil; preparedPackage = nil
            }
            do {
                try await administrator.perform(plan)
                installationProgress = String(localized: "管理员安装完成；主应用备份已保留")
                apps = await scanInventory()
                sourceResults[plan.application.id] = nil
            } catch { recordDiagnostic(.installation, appID: plan.application.id, error: error); errorMessage = String(localized: "管理员安装未完成或授权已取消。请在记录中检查恢复选项：\(error.localizedDescription)") }
        }
    }
    func restoreAdministratorInstallation(_ attempt: AdministratorInstallAttempt) {
        guard !installationBusy, !refreshing, !checking, !scanning, !SelfUpdateService.shared.sessionInProgress else { return }
        installing = true; canCancelInstallation = false; installationProgress = String(localized: "正在请求管理员授权以恢复主应用…")
        installationTask = Task { [self] in
            defer { installing = false }
            do {
                let plan = AdministratorInstallPlan(id: attempt.id, operation: .restore, application: attempt.plan.application,
                    version: attempt.plan.version, build: attempt.plan.build)
                try await administrator.perform(plan)
                apps = await scanInventory(); sourceResults = [:]
                installationProgress = String(localized: "主应用已恢复；安装包的其他系统改动未回滚")
            } catch { recordDiagnostic(.recovery, appID: attempt.plan.application.id, error: error); errorMessage = String(localized: "主应用未恢复：\(error.localizedDescription)") }
        }
    }
    func refreshInstallations() async {
        do {
            installationReceipts = try await installer.receipts()
            let receipts = installationReceipts
            backupSizes = await Task.detached {
                var sizes: [String: Int64] = [:]
                for receipt in receipts {
                    guard let path = receipt.retainedPath else { continue }
                    let root = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: root.path),
                          let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isSymbolicLinkKey]) else { continue }
                    var bytes: Int64 = 0
                    while let file = iterator.nextObject() as? URL {
                        if let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey, .isSymbolicLinkKey]), values.isSymbolicLink != true {
                            bytes += Int64(values.fileAllocatedSize ?? 0)
                        }
                    }
                    sizes[receipt.id] = bytes
                }
                return sizes
            }.value
        } catch { recordDiagnostic(.backupInspection, error: error); errorMessage = String(localized: "安装记录无法读取：\(error.localizedDescription)") }
    }
    func discardBackup(_ receipt: InstallationReceipt) {
        guard !installationBusy, !refreshing, !checking, !scanning else { return }
        installing = true
        Task {
            defer { installing = false }
            do {
                try await installer.discardBackup(receipt)
                installationProgress = String(localized: "旧版本备份已移到废纸篓")
                await refreshInstallations()
            } catch { recordDiagnostic(.backupCleanup, appID: receipt.application.id, error: error); errorMessage = String(localized: "备份未清理：\(error.localizedDescription)") }
        }
    }
    func restoreInstallation(_ receipt: InstallationReceipt) {
        guard !installationBusy, !refreshing, !checking, !scanning else { return }
        guard !SelfUpdateService.shared.sessionInProgress else { errorMessage = String(localized: "请先完成或关闭 Upovi 自身更新，再恢复其他应用。"); return }
        installing = true
        Task {
            defer { installing = false }
            do {
                try await installer.restore(receipt); await refreshInstallations()
                apps = await scanInventory()
                sourceResults = [:]; installationProgress = String(localized: "旧版本已恢复")
            } catch { recordDiagnostic(.recovery, appID: receipt.application.id, error: error); errorMessage = error.localizedDescription }
        }
    }

}
