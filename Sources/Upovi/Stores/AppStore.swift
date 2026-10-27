import AppKit
import Foundation
import Observation
import UpoviCore
import Network
import OSLog

enum AppSection: String, CaseIterable, Identifiable {
    case updates = "可用更新", all = "全部应用", downloads = "下载", history = "历史与恢复", community = "P2P 网络"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .updates: "arrow.down.circle"; case .all: "square.grid.2x2"; case .downloads: "tray.and.arrow.down"
        case .history: "clock.arrow.circlepath"; case .community: "point.3.connected.trianglepath.dotted"
        }
    }
}

@MainActor @Observable
final class AppStore {
    let downloadCenter: DownloadCenterService
    var diagnosticEvents: [DiagnosticEvent] = []
    var diagnosticsPresentation: DiagnosticSnapshot?
    var updatePolicy = UpdatePolicy()
    var policyClock = Date()
    var additionalScanDirectories: [String] = []
    var batchHistory: [BulkUpdateRecord] = []
    var bulkRecordID: UUID?
    var bulkPersistenceFailed = false
    var refreshing = false
    var bulkUpdatePresented = false
    var bulkUpdating = false
    var bulkHasRun = false
    var bulkStopRequested = false
    var bulkItems: [BulkUpdateItem] = []
    var bulkOutcomes: [String: BulkUpdateOutcome] = [:]
    var bulkCurrentID: String?
    @ObservationIgnored var bulkTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    var installationBusy: Bool {
        installing || preparedUpdate != nil || preparedPackage != nil || restoreConfirmation != nil
            || administratorRestoreConfirmation != nil || administratorCleanupConfirmation != nil || backupDeletionConfirmation != nil
            || bulkUpdating || (bulkUpdatePresented && !bulkHasRun)
    }
    var preparedUpdate: PreparedUpdate?
    var preparedPackage: PreparedInstallerPackage?
    var administratorInstallRequested = false
    var administratorRestoreConfirmation: AdministratorInstallAttempt?
    var administratorCleanupConfirmation: AdministratorInstallAttempt?
    var administrator = AdministratorInstallationService()
    var installationReceipts: [InstallationReceipt] = []
    var installationProgress = ""
    var installing = false
    var canCancelInstallation = false
    var installationConfirmation = false
    var restoreConfirmation: InstallationReceipt?
    var backupDeletionConfirmation: InstallationReceipt?
    var backupSizes: [String: Int64] = [:]
    var sourceFilter: SourceFilter = .all
    var checkHistory: [CheckHistoryEntry] = []
    var sourceOverrides: [String: SourceOverride] = [:]
    var apps: [InstalledApp] = []
    var section: AppSection? {
        didSet { preferences.set(section?.rawValue, forKey: "lastSectionV1") }
    }
    var selection: String?
    /// Whether the library's trailing detail inspector is visible; hidden by default and remembered.
    var libraryInspectorPresented: Bool {
        didSet { preferences.set(libraryInspectorPresented, forKey: "libraryInspectorPresentedV1") }
    }
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
    var networkAvailable = true
    var p2pProgress = ""
    var discoveredPublishers: [String: DiscoveredPublisher] = [:]
    var identityID = "尚未创建"
    private(set) var networkEnabled: Bool
    var p2pTransitioning = false
    var p2pBatchOffset = 0
    var p2pGeneration: UInt64 = 0
    @ObservationIgnored var p2pControlTask: Task<Void, Never>?
    var ignored: Set<String> { didSet { preferences.set(Array(ignored), forKey: "ignoredBundles") } }
    var automaticChecks: Bool {
        didSet { preferences.set(automaticChecks, forKey: "automaticChecksV1") }
    }
    var checkIntervalMinutes: Int {
        didSet { preferences.set(checkIntervalMinutes, forKey: "checkIntervalV1") }
    }
    var notificationsEnabled: Bool
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored lazy var notifications = NotificationService()
    @ObservationIgnored var installStoreUpdate: @MainActor (UpdateCandidate, InstalledApp) async throws -> Void = { try await AppStoreInstallationService().perform($0, app: $1) }
    @ObservationIgnored let installer: UpdateInstaller
    @ObservationIgnored let scanApplications: @Sendable ([URL]) async -> [InstalledApp]
    @ObservationIgnored let revalidateSources: @Sendable () async -> Void
    @ObservationIgnored let checkApplication: @Sendable (InstalledApp, SourceOverride?) async -> SourceResult
    @ObservationIgnored var installationTask: Task<Void, Never>?
    @ObservationIgnored var checkTask: Task<Void, Never>?
    @ObservationIgnored private var initialCheckStarted = false
    @ObservationIgnored var monitoringTask: Task<Void, Never>?
    @ObservationIgnored let pathMonitor = NWPathMonitor()
    @ObservationIgnored var previousPath: String?
    @ObservationIgnored let logger = Logger(subsystem: "app.upovi.Upovi", category: "operations")
    @ObservationIgnored let community = CommunityNetwork()
    @ObservationIgnored var identity: PeerIdentity?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var publisherCache: [String: [String]] = [:]

    init(preferences: AppPreferences = .shared, installer: UpdateInstaller = UpdateInstaller(),
         scanApplications: @escaping @Sendable ([URL]) async -> [InstalledApp] = { roots in await Task.detached { AppScanner.scan(roots: roots) }.value },
         revalidateSources: @escaping @Sendable () async -> Void = { @Sendable in
             await SourceHTTPClient.shared.revalidate(); await CaskCatalog.shared.invalidate(); await AppStoreCatalog.shared.invalidate()
         },
         checkApplication: @escaping @Sendable (InstalledApp, SourceOverride?) async -> SourceResult = { await UpdateChecker.check($0, override: $1) }) {
        self.downloadCenter = DownloadCenterService(coordinator: installer.downloads)
        self.preferences = preferences
        self.administrator = AdministratorInstallationService(downloads: installer.downloads)
        self.installer = installer; self.scanApplications = scanApplications; self.checkApplication = checkApplication
        self.revalidateSources = revalidateSources
        let rememberedSection = AppSection(rawValue: preferences.string(forKey: "lastSectionV1") ?? "") ?? .updates
        section = rememberedSection == .community ? .updates : rememberedSection
        libraryInspectorPresented = preferences.bool(forKey: "libraryInspectorPresentedV1")
        automaticChecks = preferences.bool(forKey: "automaticChecksV1")
        let interval = preferences.integer(forKey: "checkIntervalV1")
        checkIntervalMinutes = max(15, interval == 0 ? 60 : interval)
        notificationsEnabled = preferences.bool(forKey: "notificationsV1")
        networkEnabled = preferences.bool(forKey: GlobalP2PSettings.key)
        additionalScanDirectories = ScanLocations.normalized(preferences.stringArray(forKey: "scanDirectoriesV1") ?? [])
        if let data = preferences.data(forKey: "updatePolicyV1") { updatePolicy = (try? JSONDecoder().decode(UpdatePolicy.self, from: data)) ?? UpdatePolicy() }
        if let data = preferences.data(forKey: "bulkHistoryV1"), let records = try? JSONDecoder().decode([BulkUpdateRecord].self, from: data) {
            batchHistory = Array(records.prefix(10)).map { var record = $0; record.recoverInterrupted(); return record }
        }
        if let data = preferences.data(forKey: "diagnosticEventsV1"), let events = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
            diagnosticEvents = Array(events.prefix(50))
        }
        ignored = Set(preferences.stringArray(forKey: "ignoredBundles") ?? [])
        if let data = preferences.data(forKey: "sourceOverridesV1") {
            sourceOverrides = (try? JSONDecoder().decode([String: SourceOverride].self, from: data)) ?? [:]
        }
        if let data = preferences.data(forKey: "checkHistoryV1") {
            checkHistory = (try? JSONDecoder().decode([CheckHistoryEntry].self, from: data)) ?? []
        }
        publisherCache = preferences.dictionary(forKey: "publicPublisherCacheV2") as? [String: [String]] ?? [:]
        preferences.onFailure = { [weak self] message in self?.errorMessage = message }
        errorMessage = preferences.loadFailure
        networkStatus = networkEnabled ? "P2P 已开启，正在等待扫描应用" : "P2P 已关闭"
    }

    func setP2PEnabled(_ enabled: Bool) {
        guard enabled != networkEnabled else { return }
        if enabled {
            guard preferences.set(true, forKey: GlobalP2PSettings.key) else { return }
            networkEnabled = true
            networkStatus = "P2P 已开启，正在连接…"
        } else {
            networkEnabled = false
            if !preferences.set(false, forKey: GlobalP2PSettings.key) {
                errorMessage = "P2P 已停止，但关闭设置未能保存。下次启动前请修复设置目录的可写性。"
            }
            communityResults = [:]; discoveredPublishers = [:]
            networkStatus = "P2P 已关闭，已缓存的公开记录会按有效期过期"
        }
        restartP2P()
    }

    var visibleApps: [InstalledApp] {
        apps.filter { app in
            let matches = search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search)
            guard matches else { return false }
            if section == .updates { return !ignored.contains(app.bundleID) && assessment(for: app).hasUpdate }
            if sourceFilter == .ignored { return ignored.contains(app.bundleID) }
            return sourceFilter.includes(sourceResults[app.id]?.status, isAppStore: app.isAppStore)
        }
    }
    var selectedApp: InstalledApp? { apps.first { $0.id == selection } }
    var updateCount: Int { apps.filter { !ignored.contains($0.bundleID) && assessment(for: $0).hasUpdate }.count }
    var communityApps: [InstalledApp] { apps.filter { !assessment(for: $0).communityLeads.isEmpty } }

    func assessment(for app: InstalledApp) -> UpdateAssessment {
        UpdateAssessment(app: app, sourceResult: sourceResults[app.id].map { updatePolicy.filtering($0, app: app, now: policyClock) },
            reports: networkEnabled ? communityResults[app.id] ?? [] : [])
    }

    /// Run once per store lifetime, independently of the optional periodic schedule.
    func startInitialCheck() {
        guard !initialCheckStarted else { return }
        initialCheckStarted = true
        // A populated store already has an owner-driven refresh or preview data.
        guard apps.isEmpty, !operationBusy else { return }
        refreshAll()
    }

    func scan() async {
        guard !scanning, !checking, !installationBusy else { return }
        scanning = true
        // A background community lookup must not block an explicit inventory refresh.
        if networkEnabled { restartP2P() }
        let found = await scanInventory()
        apps = found; sourceResults = [:]; communityResults = [:]
        if !apps.contains(where: { $0.id == selection }) { selection = apps.first?.id }
        scanning = false
        logger.info("scan completed count=\(found.count)")
        p2pBatchOffset = 0
        if networkEnabled && !refreshing { restartP2P() }
    }

    func refreshAll() {
        guard !refreshing, !scanning, !checking, !installationBusy else { return }
        refreshing = true
        checkTask = Task {
            defer {
                refreshing = false
                if networkEnabled { restartP2P() }
            }
            await scan()
            guard !Task.isCancelled else { return }
            guard networkAvailable else { errorMessage = "应用已重新扫描；当前没有可用网络，联网后再检查更新。"; return }
            await revalidateSources()
            guard !Task.isCancelled else { return }
            checking = true; lastCheckAttempt = Date()
            await checkUpdates()
        }
    }

    func beginChecking() {
        guard !refreshing, !checking, !scanning, !installationBusy else { return }
        guard networkAvailable else { errorMessage = "当前没有可用网络，联网后再检查更新。"; return }
        checking = true; lastCheckAttempt = Date()
        checkTask = Task { await checkUpdates() }
    }
    func cancelChecking() { checkTask?.cancel() }
    private func checkUpdates() async {
        completedChecks = 0; sourceResults = [:]
        defer { checking = false }
        let overrides = sourceOverrides
        let snapshot = apps
        let checkApplication = checkApplication
        await withTaskGroup(of: SourceResult.self) { group in
            var iterator = snapshot.makeIterator()
            for _ in 0..<5 { if let app = iterator.next() { group.addTask { await checkApplication(app, overrides[app.bundleID]) } } }
            for await result in group {
                if Task.isCancelled { group.cancelAll(); break }
                sourceResults[result.appID] = result; completedChecks += 1
                if let app = iterator.next() { group.addTask { await checkApplication(app, overrides[app.bundleID]) } }
            }
        }
        guard !Task.isCancelled else { logger.info("source check cancelled"); return }
        lastChecked = Date()
        let failures = sourceResults.values.filter { [.failed, .partial].contains($0.status) }.count
        let updates = snapshot.filter { assessment(for: $0).hasUpdate }.count
        checkHistory.insert(.init(date: Date(), applications: snapshot.count, updates: updates, failed: failures), at: 0)
        checkHistory = Array(checkHistory.prefix(100))
        if let data = try? JSONEncoder().encode(checkHistory) { preferences.set(data, forKey: "checkHistoryV1") }
        logger.info("source check completed apps=\(snapshot.count) updates=\(updates) failures=\(failures)")
        if notificationsEnabled { await notifications.announce(snapshot, results: actionableSourceResults, ignored: ignored) }
    }

    func toggleIgnored(_ app: InstalledApp) {
        if ignored.contains(app.bundleID) { ignored.remove(app.bundleID) } else { ignored.insert(app.bundleID) }
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
