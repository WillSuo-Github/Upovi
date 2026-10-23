import AppKit
import Foundation
import Observation
import UpoviCore
import Network
import OSLog

enum AppSection: String, CaseIterable, Identifiable {
    case updates = "可用更新", all = "全部应用", community = "P2P 网络", ignored = "已忽略"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .updates: "arrow.down.circle"; case .all: "square.grid.2x2"; case .community: "point.3.connected.trianglepath.dotted"; case .ignored: "eye.slash" }
    }
}

@MainActor @Observable
final class AppStore {
    var preparedUpdate: PreparedUpdate?
    var installationReceipts: [InstallationReceipt] = []
    var installationProgress = ""
    var installing = false
    var canCancelInstallation = false
    var installationConfirmation = false
    var restoreConfirmation: InstallationReceipt?
    var checkHistory: [CheckHistoryEntry] = []
    var sourceOverrides: [String: SourceOverride] = [:]
    var apps: [InstalledApp] = []
    var section: AppSection? = AppSection(rawValue: AppPreferences.shared.string(forKey: "lastSectionV1") ?? "") ?? .all {
        didSet { AppPreferences.shared.set(section?.rawValue, forKey: "lastSectionV1") }
    }
    var selection: String?
    var search = ""
    var scanning = false
    var checking = false
    var syncing = false
    var sourceResults: [String: SourceResult] = [:]
    var communityResults: [String: [UpdateCandidate]] = [:]
    var errorMessage: String?
    var networkStatus = "尚未连接公网 DHT"
    var lastCheckAttempt: Date?
    var lastSyncAttempt: Date?
    var lastChecked: Date?
    var lastSynced: Date?
    var completedChecks = 0
    var p2pProgress = ""
    var discoveredPublishers: [String: DiscoveredPublisher] = [:]
    var identityID = "尚未创建"
    var networkEnabled: Bool {
        didSet {
            AppPreferences.shared.set(networkEnabled, forKey: "publicDiscoveryEnabledV2")
            if !networkEnabled {
                syncTask?.cancel(); networkStatus = "P2P 已关闭"; communityResults = [:]; discoveredPublishers = [:]
                Task { await community.stopSharing() }
            } else { beginSync() }
        }
    }
    var sharingEnabled: Bool {
        didSet {
            AppPreferences.shared.set(sharingEnabled, forKey: "publicSharingEnabledV2")
            syncTask?.cancel()
            if !sharingEnabled {
                networkStatus = networkEnabled ? "公开共享已停止，已缓存记录无法立即撤回" : "P2P 已关闭"
                logger.info("public sharing stopped")
                Task { await community.stopSharing() }
            }
            if networkEnabled && !syncing { beginSync() }
        }
    }
    var selectedBundles: Set<String> {
        didSet {
            AppPreferences.shared.set(Array(selectedBundles), forKey: "selectedBundles")
            syncTask?.cancel()
            communityResults = [:]
            Task { await community.stopSharing() }
        }
    }
    var ignored: Set<String> { didSet { AppPreferences.shared.set(Array(ignored), forKey: "ignoredBundles") } }
    var automaticChecks = AppPreferences.shared.bool(forKey: "automaticChecksV1") {
        didSet { AppPreferences.shared.set(automaticChecks, forKey: "automaticChecksV1") }
    }
    var checkIntervalMinutes: Int = max(15, AppPreferences.shared.integer(forKey: "checkIntervalV1") == 0 ? 60 : AppPreferences.shared.integer(forKey: "checkIntervalV1")) {
        didSet { AppPreferences.shared.set(checkIntervalMinutes, forKey: "checkIntervalV1") }
    }
    var notificationsEnabled = AppPreferences.shared.bool(forKey: "notificationsV1")
    @ObservationIgnored let notifications = NotificationService()
    @ObservationIgnored let installer = UpdateInstaller()
    @ObservationIgnored var installationTask: Task<Void, Never>?
    @ObservationIgnored var checkTask: Task<Void, Never>?
    @ObservationIgnored var monitoringTask: Task<Void, Never>?
    @ObservationIgnored let pathMonitor = NWPathMonitor()
    @ObservationIgnored var previousPath: String?
    @ObservationIgnored let logger = Logger(subsystem: "app.upovi.Upovi", category: "operations")
    @ObservationIgnored let community = CommunityNetwork()
    @ObservationIgnored var identity: PeerIdentity?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var publisherCache: [String: [String]] = [:]

    init() {
        networkEnabled = AppPreferences.shared.bool(forKey: "publicDiscoveryEnabledV2")
        sharingEnabled = AppPreferences.shared.bool(forKey: "publicSharingEnabledV2")
        selectedBundles = Set(AppPreferences.shared.stringArray(forKey: "selectedBundles") ?? [])
        ignored = Set(AppPreferences.shared.stringArray(forKey: "ignoredBundles") ?? [])
        if let data = AppPreferences.shared.data(forKey: "sourceOverridesV1") {
            sourceOverrides = (try? JSONDecoder().decode([String: SourceOverride].self, from: data)) ?? [:]
        }
        if let data = AppPreferences.shared.data(forKey: "checkHistoryV1") {
            checkHistory = (try? JSONDecoder().decode([CheckHistoryEntry].self, from: data)) ?? []
        }
        publisherCache = AppPreferences.shared.dictionary(forKey: "publicPublisherCacheV2") as? [String: [String]] ?? [:]
        AppPreferences.shared.onFailure = { [weak self] message in self?.errorMessage = message }
        errorMessage = AppPreferences.shared.loadFailure
    }

    var visibleApps: [InstalledApp] {
        apps.filter { app in
            let matches = search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search)
            guard matches else { return false }
            switch section {
            case .updates: return !ignored.contains(app.bundleID) && assessment(for: app).hasUpdate
            case .ignored: return ignored.contains(app.bundleID)
            default: return true
            }
        }
    }
    var selectedApp: InstalledApp? { apps.first { $0.id == selection } }
    var updateCount: Int { apps.filter { !ignored.contains($0.bundleID) && assessment(for: $0).hasUpdate }.count }
    var communityApps: [InstalledApp] { apps.filter { !assessment(for: $0).communityLeads.isEmpty } }

    func assessment(for app: InstalledApp) -> UpdateAssessment {
        UpdateAssessment(app: app, sourceResult: sourceResults[app.id],
            reports: networkEnabled ? communityResults[app.id] ?? [] : [])
    }

    func scan() async {
        guard !scanning, !checking, !syncing, !installing else { return }
        scanning = true
        let found = await Task.detached(priority: .userInitiated) { AppScanner.scan() }.value
        apps = found; sourceResults = [:]; communityResults = [:]
        if !apps.contains(where: { $0.id == selection }) { selection = apps.first?.id }
        scanning = false
        logger.info("scan completed count=\(found.count)")
    }

    func beginChecking() {
        guard !checking, !scanning, !installing else { return }
        checking = true; lastCheckAttempt = Date()
        checkTask = Task { await checkUpdates() }
    }
    func cancelChecking() { checkTask?.cancel() }
    private func checkUpdates() async {
        completedChecks = 0; sourceResults = [:]
        defer { checking = false }
        let overrides = sourceOverrides
        let snapshot = apps
        await withTaskGroup(of: SourceResult.self) { group in
            var iterator = snapshot.makeIterator()
            for _ in 0..<5 { if let app = iterator.next() { group.addTask { await UpdateChecker.check(app, override: overrides[app.bundleID]) } } }
            for await result in group {
                if Task.isCancelled { group.cancelAll(); break }
                sourceResults[result.appID] = result; completedChecks += 1
                if let app = iterator.next() { group.addTask { await UpdateChecker.check(app, override: overrides[app.bundleID]) } }
            }
        }
        guard !Task.isCancelled else { logger.info("source check cancelled"); return }
        lastChecked = Date()
        let failures = sourceResults.values.filter { [.failed, .partial].contains($0.status) }.count
        let updates = snapshot.filter { assessment(for: $0).hasUpdate }.count
        checkHistory.insert(.init(date: Date(), applications: snapshot.count, updates: updates, failed: failures), at: 0)
        checkHistory = Array(checkHistory.prefix(100))
        if let data = try? JSONEncoder().encode(checkHistory) { AppPreferences.shared.set(data, forKey: "checkHistoryV1") }
        logger.info("source check completed apps=\(snapshot.count) updates=\(updates) failures=\(failures)")
        if notificationsEnabled { await notifications.announce(snapshot, results: sourceResults, ignored: ignored) }
    }

    func setSelected(_ app: InstalledApp, enabled: Bool) {
        if enabled {
            guard selectedBundles.count < 20 else { errorMessage = "第一版每次最多检测 20 个 P2P 应用，以限制公共 DHT 流量。"; return }
            selectedBundles.insert(app.bundleID)
        } else { selectedBundles.remove(app.bundleID) }
    }

    func toggleIgnored(_ app: InstalledApp) {
        if ignored.contains(app.bundleID) { ignored.remove(app.bundleID) } else { ignored.insert(app.bundleID) }
    }

    func beginSync() {
        guard !syncing, !scanning, networkEnabled else { return }
        syncing = true; lastSyncAttempt = Date()
        logger.info("community sync started")
        syncTask = Task { await syncCommunity() }
    }

    private func loadIdentity() throws -> PeerIdentity {
        if let identity { return identity }
        let loaded = try PeerIdentity.loadOrCreate(account: "public-dht-v2"); identity = loaded; identityID = loaded.invitation.shortID
        return loaded
    }

    private func syncCommunity() async {
        syncing = true; communityResults = [:]; discoveredPublishers = [:]
        defer { syncing = false; p2pProgress = "" }
        let scope = Array(Dictionary(apps.filter { selectedBundles.contains($0.bundleID) }.map { ($0.bundleID + $0.channel, $0) }, uniquingKeysWith: { a, _ in a }).values.prefix(20))
        guard !scope.isEmpty else { networkStatus = "先在应用列表选择 P2P 检测范围，无需添加节点或交换邀请"; return }
        var announcements = 0, storage = 0, directoryAcks = 0, directoryCandidates = 0, failedRecords = 0, rejectedReports = 0, found = 0, responders = 0, endpoints = 0, unreachable = 0, failures = 0
        var lastFailure = ""
        networkStatus = "正在自动发现应用主题中的公网节点…"
        do {
            await community.stopSharing()
            try Task.checkCancellation()
            let own = sharingEnabled ? try loadIdentity() : nil
            try await community.prepare(apps: scope, sharingIdentity: own)
        } catch { if !Task.isCancelled { networkStatus = error.localizedDescription }; return }
        for (index, app) in scope.enumerated() {
            if Task.isCancelled || !networkEnabled { return }
            p2pProgress = "\(index + 1)/\(scope.count) · \(app.name)"
            if sharingEnabled, selectedBundles.contains(app.bundleID) {
                do {
                    let result = try await community.publish(app)
                    announcements += result.announcements; storage += result.storage; directoryAcks += result.directory
                } catch { if Task.isCancelled { return }; failures += 1; lastFailure = error.localizedDescription }
            }
            do {
                let topic = CommunityTopic.hash(app).base64EncodedString()
                let keys = (publisherCache[topic] ?? []).compactMap { Data(base64Encoded: $0) }
                let result = try await community.discover(app, cachedKeys: keys)
                if Task.isCancelled || !networkEnabled || !selectedBundles.contains(app.bundleID) { return }
                responders += result.responders; endpoints += result.endpoints; unreachable += result.unreachable
                directoryCandidates += result.directoryCandidates; failedRecords += result.failedRecords
                rejectedReports += result.rejectedReports
                var discoveredKeys = publisherCache[topic] ?? []
                for observation in result.observations {
                    if !discoveredKeys.contains(observation.id) { discoveredKeys.append(observation.id) }
                    var publisher = discoveredPublishers[observation.id] ?? DiscoveredPublisher(id: observation.id, shortID: observation.shortID, applications: [], lastSeen: observation.report.observedAt)
                    publisher.applications.insert(app.name)
                    publisher.lastSeen = max(publisher.lastSeen, observation.report.observedAt)
                    discoveredPublishers[observation.id] = publisher
                    let report = observation.report
                    guard VersionOrder.isNewer(version: report.version, build: report.build, than: app) else { continue }
                    communityResults[app.id, default: []].append(.init(version: report.version, build: report.build,
                        source: "公开节点 \(observation.shortID)", isCommunity: true, url: nil,
                        observedAt: report.observedAt, peerID: observation.id, expiresAt: report.expiresAt))
                    found += 1
                }
                publisherCache[topic] = Array(discoveredKeys.prefix(16))
                // Keep only bounded public keys for currently selected applications, never invitation secrets.
                let activeTopics = Set(scope.map { CommunityTopic.hash($0).base64EncodedString() })
                publisherCache = publisherCache.filter { activeTopics.contains($0.key) }
                AppPreferences.shared.set(publisherCache, forKey: "publicPublisherCacheV2")
            } catch { if Task.isCancelled { return }; failures += 1; lastFailure = error.localizedDescription }
            try? await Task.sleep(for: .milliseconds(400))
        }
        lastSynced = Date()
        logger.info("community sync completed apps=\(scope.count) publishers=\(self.discoveredPublishers.count) leads=\(found) failures=\(failures)")
        networkStatus = "DHT 响应 \(responders) 次 · 端点 \(endpoints) 个 · 索引候选 \(directoryCandidates) 个 · 验签节点 \(discoveredPublishers.count) 个 · 更高版本线索 \(found) 条"
        if sharingEnabled { networkStatus += "\n主题登记确认 \(announcements) 次 · 索引登记确认 \(directoryAcks) 次 · 记录存储确认 \(storage) 次" }
        if unreachable > 0 { networkStatus += "\n\(unreachable) 个采样端点未返回有效记录，可能离线或受 NAT／防火墙限制" }
        if failedRecords > 0 { networkStatus += "\n\(failedRecords) 个索引候选未返回有效签名记录" }
        if rejectedReports > 0 { networkStatus += "\n已拒绝 \(rejectedReports) 条回放、冲突或无效报告" }
        if failures > 0 { networkStatus += "\n\(failures) 项失败：\(lastFailure)" }
    }


    func open(_ url: URL?) {
        guard let url, ["https", "macappstore"].contains(url.scheme ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct DiscoveredPublisher: Identifiable {
    let id: String
    let shortID: String
    var applications: Set<String>
    var lastSeen: Date
}
