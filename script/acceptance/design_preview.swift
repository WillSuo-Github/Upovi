// Synthetic, offline design preview. No scanning, source checks, P2P traffic, downloads or installation.
import AppKit
import SwiftUI
@testable import UpoviCore

final class DesignPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

@MainActor private enum Fixture {
    struct Entry { let name: String; let bundle: String; let version: String; let file: String; var store = false; var team: String? = "SYNTHETIC" }
    static let entries: [Entry] = [
        .init(name: "Google Chrome", bundle: "com.google.Chrome", version: "141.0.7390.54", file: "Google Chrome"),
        .init(name: "Visual Studio Code", bundle: "com.microsoft.VSCode", version: "1.104.2", file: "Visual Studio Code"),
        .init(name: "Slack", bundle: "com.tinyspeck.slackmacgap", version: "4.46.99", file: "Slack"),
        .init(name: "Figma", bundle: "com.figma.Desktop", version: "125.8.8", file: "Figma"),
        .init(name: "Things", bundle: "com.culturedcode.ThingsMac", version: "3.22.4", file: "Things3", store: true),
        .init(name: "Telegram", bundle: "ru.keepcoder.Telegram", version: "12.0.1", file: "Telegram", store: true),
        .init(name: "IINA", bundle: "com.colliderli.iina", version: "1.3.5", file: "IINA"),
        .init(name: "Discord", bundle: "com.hnc.Discord", version: "0.0.356", file: "Discord"),
        .init(name: "Docker", bundle: "com.docker.docker", version: "4.46.0", file: "Docker"),
        .init(name: "Tailscale", bundle: "io.tailscale.ipn.macos", version: "1.88.3", file: "Tailscale", store: true),
        .init(name: "Alfred 5", bundle: "com.runningwithcrayons.Alfred", version: "5.7", file: "Alfred 5"),
        .init(name: "Blender", bundle: "org.blenderfoundation.blender", version: "4.5.3", file: "Blender"),
        .init(name: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", version: "1.7.28", file: "Cursor"),
        .init(name: "Steam", bundle: "com.valvesoftware.steam", version: "4.0", file: "Steam", team: nil),
        .init(name: "UTM", bundle: "com.utmapp.UTM", version: "4.6.5", file: "UTM"),
        .init(name: "Karabiner-Elements", bundle: "org.pqrs.Karabiner-Elements.Settings", version: "15.5.0", file: "Karabiner-Elements"),
        .init(name: "Mos", bundle: "com.caldis.Mos", version: "3.5.0", file: "Mos"),
        .init(name: "Tower", bundle: "com.fournova.Tower3", version: "13.1", file: "Tower"),
        .init(name: "LyricsX", bundle: "ddddxxx.LyricsX", version: "1.6.2", file: "LyricsX"),
        .init(name: "GitHub Desktop", bundle: "com.github.GitHubClient", version: "3.5.2", file: "GitHub Desktop"),
    ]

    static func apps() -> [InstalledApp] {
        entries.map { entry in
            let path = "/Applications/\(entry.file).app"
            return InstalledApp(name: entry.name, bundleID: entry.bundle, version: entry.version, build: "100",
                                path: FileManager.default.fileExists(atPath: path) ? path : "/synthetic/\(entry.file).app",
                                teamID: entry.team, isAppStore: entry.store)
        }
    }

    static let notes = """
    • 新增标签页分组与快速切换
    • 修复在外接显示器上窗口位置丢失的问题
    • 提升大文件打开速度约 30%
    • 安全性更新
    """

    static func results(for apps: [InstalledApp]) -> [String: SourceResult] {
        func update(_ app: InstalledApp, _ version: String, source: String, download: Bool = true, notes: Bool = true, storeID: UInt64? = nil) -> SourceResult {
            .init(appID: app.id, candidates: [.init(version: version, source: source, isCommunity: false, url: URL(string: "https://example.invalid/release"),
                download: download ? .init(url: URL(string: "https://example.invalid/update.zip")!, sha256: String(repeating: "a", count: 64)) : nil,
                releaseNotes: notes ? Self.notes : nil, appStoreID: storeID)], note: "\(source) 提供了新版本", status: .updates, appStoreID: storeID)
        }
        var results: [String: SourceResult] = [:]
        for (index, app) in apps.enumerated() {
            let result: SourceResult
            switch index {
            case 0: result = update(app, "141.0.7390.108", source: "Homebrew")
            case 1: result = update(app, "1.105.0", source: "Sparkle appcast")
            case 2: result = update(app, "4.47.59", source: "Homebrew", download: false)
            case 3: result = update(app, "126.1.4", source: "Sparkle appcast", notes: false)
            case 4: result = update(app, "3.22.5", source: "App Store", download: false, storeID: 904280696)
            case 6: result = update(app, "1.4.0", source: "GitHub releases")
            case 13: result = update(app, "4.1", source: "Homebrew")
            case 8: result = .init(appID: app.id, candidates: [], note: "Sparkle appcast 请求失败（HTTP 503）", status: .failed,
                                   checks: [.init(.appcast, .failed, error: HTTPStatusError(statusCode: 503))])
            case 9: result = .init(appID: app.id, candidates: [], note: "App Store 已是最新版本", status: .appStore, appStoreID: 1475387142)
            case 11, 16: result = .init(appID: app.id, candidates: [], note: "未找到可用的更新来源", status: .unsupported,
                                        manualURL: URL(string: "https://example.invalid/download"))
            case 14: result = .init(appID: app.id, candidates: [], note: "部分来源检测失败", status: .partial)
            default: result = .init(appID: app.id, candidates: [], note: "Homebrew 与 Sparkle 均报告为最新版本", status: .current)
            }
            results[app.id] = result
        }
        return results
    }

    static func community(for apps: [InstalledApp]) -> [String: [UpdateCandidate]] {
        func lead(_ version: String, peer: String, hours: Double) -> UpdateCandidate {
            .init(version: version, source: "公开节点 \(peer.prefix(8))", isCommunity: true, url: nil,
                  observedAt: Date().addingTimeInterval(-hours * 3600), peerID: peer, expiresAt: Date().addingTimeInterval(20 * 3600))
        }
        return [apps[0].id: [lead("141.0.7390.108", peer: "a91f03c2d4", hours: 2), lead("141.0.7390.108", peer: "77be01aa90", hours: 5)],
                apps[7].id: [lead("0.0.360", peer: "c0ffee1234", hours: 1)],
                apps[11].id: [lead("4.5.4", peer: "a91f03c2d4", hours: 3), lead("4.5.4", peer: "5d6e7f8091", hours: 7)]]
    }

    static func writeHistory(root: URL, apps: [InstalledApp]) throws {
        let files = FileManager.default
        let journal = root.appending(path: "Journal"); try files.createDirectory(at: journal, withIntermediateDirectories: true)
        let backups = root.appending(path: "Backups"); try files.createDirectory(at: backups, withIntermediateDirectories: true)
        for (offset, (index, version, state)) in [(10, "5.6", InstallationReceipt.State.installed), (17, "3.4.0", .restored), (18, "1.6.1", .failed)].enumerated() {
            let id = UUID().uuidString
            let backup = backups.appending(path: "\(id).app"); try files.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data(count: 4_200_000 * (offset + 1)).write(to: backup.appending(path: "payload"))
            let receipt = InstallationReceipt(id: id, date: Date().addingTimeInterval(-Double(offset + 1) * 86_400), application: apps[index],
                newVersion: version, newBuild: "", backupPath: backup.path, incomingPath: "", state: state, displacedPath: state == .restored ? backup.path : nil)
            try JSONEncoder().encode(receipt).write(to: journal.appending(path: id + ".json"))
        }
        var records: [DownloadRecord] = []
        var verified = DownloadRecord(app: apps[1], targetVersion: "1.105.0"); verified.state = .verified; verified.received = 142_000_000; verified.expected = 142_000_000
        var failed = DownloadRecord(app: apps[6], targetVersion: "1.4.0"); failed.state = .failed; failed.received = 18_500_000; failed.expected = 61_000_000
        failed.retries = 3; failed.issue = .init(HTTPStatusError(statusCode: 503))
        var paused = DownloadRecord(app: apps[0], targetVersion: "141.0.7390.108"); paused.state = .paused; paused.received = 88_000_000; paused.expected = 231_000_000; paused.resumedBytes = 40_000_000
        var cancelled = DownloadRecord(app: apps[13], targetVersion: "4.1"); cancelled.state = .cancelled; cancelled.received = 2_000_000; cancelled.expected = 12_000_000
        records = [paused, verified, failed, cancelled]
        try JSONEncoder().encode(records).write(to: root.appending(path: "tasks.json"))
    }
}

actor DesignPreviewTransfer {
    func run(_ destination: URL, phase: @Sendable (ArtifactDownloadPhase) -> Void, progress: @Sendable (Int64, Int64) -> Void) async throws {
        phase(.downloading)
        var received: Int64 = 0
        while received < 90_000_000 { try await Task.sleep(for: .milliseconds(200)); received += 600_000; progress(received, 90_000_000) }
        phase(.verifying)
        try Data("Synthetic design preview archive".utf8).write(to: destination)
    }
}

@main struct DesignPreview: App {
    @NSApplicationDelegateAdaptor(DesignPreviewDelegate.self) private var delegate
    @State private var store: AppStore
    private let coordinator: DownloadCoordinator
    private let transfer = DesignPreviewTransfer()
    private let root: URL

    init() {
        guard let path = option("--root") else { fatalError("Explicit --root required") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else { fatalError("Use an unlinked private .local directory") }
        self.root = root
        let apps = Fixture.apps()
        if !FileManager.default.fileExists(atPath: root.appending(path: "Journal").path) { try? Fixture.writeHistory(root: root, apps: apps) }
        let transfer = transfer
        let coordinator = DownloadCoordinator(storageURL: root.appending(path: "tasks.json")) { _, _, destination, phase, _, progress in
            try await transfer.run(destination, phase: phase, progress: progress)
        }
        self.coordinator = coordinator
        let p2p = option("--p2p") != "off"
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(p2p, forKey: GlobalP2PSettings.key); preferences.set(false, forKey: "notificationsV1")
        let results = Fixture.results(for: apps).mapValues { result in
            CommandLine.arguments.contains("--no-updates") && result.status == .updates
                ? SourceResult(appID: result.appID, candidates: [], note: "来源报告为最新版本", status: .current) : result
        }
        let store = AppStore(preferences: preferences, installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: coordinator),
                             scanApplications: { _ in apps }, revalidateSources: { },
                             checkApplication: { app, _ in try? await Task.sleep(for: .milliseconds(120)); return results[app.id] ?? .init(appID: app.id, candidates: [], note: "Fixture", status: .current) })
        store.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"), downloads: coordinator)
        // Keep the preview offline: no path monitor, scheduled checks or DHT synchronization.
        store.monitoringTask = Task { }
        store.p2pTransitioning = true
        store.apps = apps
        store.sourceResults = results
        store.communityResults = Fixture.community(for: apps)
        store.ignored = [apps[19].bundleID]
        store.lastChecked = Date().addingTimeInterval(-18 * 60)
        store.lastSynced = Date().addingTimeInterval(-6 * 60)
        store.networkStatus = p2p ? "已同步 1–20/20 个应用 · 验签节点 4 个 · 更高版本线索 3 条\nDHT 响应 212 次 · 端点 64 个 · 索引候选 9 个" : "P2P 已关闭"
        if p2p {
            for (id, names, minutes) in [("a91f03c2d4", ["Google Chrome", "Blender", "Slack"], 4.0), ("77be01aa90", ["Google Chrome"], 22),
                                         ("c0ffee1234", ["Discord", "IINA", "Docker"], 41), ("5d6e7f8091", ["Blender"], 95)] {
                store.discoveredPublishers[id] = .init(id: id, shortID: String(id.prefix(8)), applications: Set(names), lastSeen: Date().addingTimeInterval(-minutes * 60))
            }
        }
        store.checkHistory = (0..<6).map { .init(date: Date().addingTimeInterval(-Double($0) * 3 * 3600 - 1080), applications: 20, updates: 7 - $0 % 3, failed: $0 % 2) }
        store.selection = option("--select").flatMap { name in apps.first { $0.name == name }?.id } ?? apps[0].id
        if let section = option("--section") { store.section = AppSection.allCases.first { "\($0)" == section } }
        _store = State(initialValue: store)
        switch option("--present") {
        case "bulk": Task { @MainActor in try? await Task.sleep(for: .seconds(1)); store.reviewAllUpdates() }
        case "check": Task { @MainActor in try? await Task.sleep(for: .seconds(1)); store.beginChecking() }
        case "diagnostics": Task { @MainActor in try? await Task.sleep(for: .seconds(1)); store.diagnosticsPresentation = store.diagnosticSnapshot() }
        default: break
        }
    }

    var body: some Scene {
        WindowGroup("Upovi", id: "main") { ContentView(store: store).frame(minWidth: 1000, minHeight: 650).background(SettingsOpener()) }
            .defaultSize(width: 1240, height: 780)
            .commands {
                CommandMenu("Fixture") {
                    Button("Start synthetic download") {
                        let app = store.apps[3], root = root, coordinator = coordinator
                        Task { try? await coordinator.download(.init(url: URL(string: "https://example.invalid/Figma.zip")!, sha256: String(repeating: "a", count: 64)),
                                                               app: app, targetVersion: "126.1.4", to: root.appending(path: "Output-\(UUID().uuidString).zip"), progress: { _, _ in }) }
                    }
                    Button("Show bulk review") { store.reviewAllUpdates() }
                    Button("Show diagnostics") { store.diagnosticsPresentation = store.diagnosticSnapshot() }
                }
            }
        Settings { SettingsView(store: store) }
    }
}

private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.task {
            guard option("--present") == "settings" else { return }
            try? await Task.sleep(for: .seconds(1)); openSettings()
        }
    }
}
