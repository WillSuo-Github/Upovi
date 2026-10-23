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
                if automaticChecks && !apps.isEmpty && !scanning && !checking && !installing &&
                    (lastCheckAttempt.map { Date().timeIntervalSince($0) >= Double(checkIntervalMinutes * 60) } ?? true) { beginChecking() }
                if networkEnabled && !syncing && !scanning && !installing &&
                    (lastSyncAttempt.map { Date().timeIntervalSince($0) >= 600 } ?? true) { beginSync() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.wiredEthernet))-\(path.usesInterfaceType(.cellular))"
            Task { @MainActor in
                guard let self else { return }
                defer { self.previousPath = signature }
                if self.previousPath != nil && self.previousPath != signature { self.recoverNetwork() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.upovi.path"))
    }
    func recoverNetwork() {
        guard networkEnabled else { return }
        syncTask?.cancel()
        networkStatus = "网络已变化，正在重新连接…"
        Task {
            await community.resetRouting()
            if networkEnabled && !syncing { beginSync() }
        }
    }
    func setNotifications(_ enabled: Bool) async {
        let granted = enabled ? await notifications.requestAccess() : false
        notificationsEnabled = granted
        UserDefaults.standard.set(granted, forKey: "notificationsV1")
        if enabled && !granted { errorMessage = "通知权限未开启，可在系统设置中允许 Upovi 通知。" }
    }
    func configureSource(for app: InstalledApp, feed: String, repository: String) throws {
        let feed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = feed.isEmpty ? nil : URL(string: feed)
        guard feed.isEmpty || (url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil),
              repository.isEmpty || GitHubRelease.validRepository(repository) else { throw PeerError.invalid("Use an HTTPS appcast URL and a GitHub owner/repository") }
        sourceOverrides[app.bundleID] = .init(appcast: url, githubRepository: repository.isEmpty ? nil : repository)
        let data = try JSONEncoder().encode(sourceOverrides)
        UserDefaults.standard.set(data, forKey: "sourceOverridesV1")
        sourceResults[app.id] = nil
    }
    func prepareInstallation(_ candidate: UpdateCandidate, app: InstalledApp) {
        guard !installing, !checking, !scanning else { return }
        installing = true; canCancelInstallation = true; installationProgress = "正在下载并验证更新…"
        installationTask = Task { [self] in
            defer { installing = false; canCancelInstallation = false }
            do {
                let value = try await installer.prepare(app: app, candidate: candidate) { [weak self] received, expected in
                    Task { @MainActor in
                        self?.installationProgress = expected > 0 ? "下载中 \(received * 100 / expected)%" : "已下载 \(received / 1_000_000) MB"
                    }
                }
                preparedUpdate = value; installationConfirmation = true; installationProgress = "更新已验证，等待安装确认"
            } catch { installationProgress = "下载或验证未完成"; if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    func cancelInstallation() { installationTask?.cancel() }
    func discardInstallation() {
        if let value = preparedUpdate { Task { await installer.discard(value.id) } }
        preparedUpdate = nil; installationConfirmation = false; installationProgress = ""
    }
    func confirmInstallation() {
        guard let value = preparedUpdate, !installing else { return }
        installationConfirmation = false; installing = true; canCancelInstallation = false; installationProgress = "正在安装，旧版本将保留为备份…"
        installationTask = Task { [self] in
            defer { installing = false; preparedUpdate = nil }
            do {
                _ = try await installer.install(value.id)
                installationProgress = "安装完成，可在安装记录中恢复旧版本"
                await refreshInstallations()
                let found = await Task.detached { AppScanner.scan() }.value
                apps = found; sourceResults[value.application.id] = nil
                logger.info("installation completed")
            } catch { errorMessage = error.localizedDescription; installationProgress = "安装未完成，原应用或恢复备份已保留" }
        }
    }
    func refreshInstallations() async { installationReceipts = (try? await installer.receipts()) ?? [] }
    func restoreInstallation(_ receipt: InstallationReceipt) {
        guard !installing else { return }
        installing = true
        Task {
            defer { installing = false }
            do {
                try await installer.restore(receipt); await refreshInstallations()
                apps = await Task.detached { AppScanner.scan() }.value
                sourceResults = [:]; installationProgress = "旧版本已恢复"
            } catch { errorMessage = error.localizedDescription }
        }
    }

}
