// Explicit isolated acceptance harness. Never included in the distributed application.
import AppKit
import SwiftUI
import UpoviCore

actor AcceptanceSource {
    var repaired = false
    func repair() { repaired = true }
    func check(_ app: InstalledApp) -> SourceResult {
        guard VersionOrder.isNewer(version: "2.0.4", than: app) else {
            return .init(appID: app.id, candidates: [], note: "Fixture current", status: .current)
        }
        let bad = app.path.hasSuffix("B.app") && !repaired
        let candidate = UpdateCandidate(version: "2.0.4", build: "111", source: "Official Rectangle acceptance fixture", isCommunity: false,
            url: URL(string: "https://github.com/rxhanson/Rectangle/releases/tag/v2.0.4"),
            download: .init(url: URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.4/Rectangle2.0.4.zip")!,
                sha256: bad ? String(repeating: "0", count: 64) : "0b9b8b11edeb3237e3224c619a6f6bfb5e5996a477048be6ff4b98b0346aedc9"))
        return .init(appID: app.id, candidates: [candidate], note: "Isolated official release", status: .updates)
    }
}

final class AcceptanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct BulkAcceptanceApp: App {
    @NSApplicationDelegateAdaptor(AcceptanceDelegate.self) private var delegate
    @State private var store: AppStore
    private let root: URL
    private let source: AcceptanceSource
    init() {
        guard let i = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(i + 1) else { fatalError("Explicit --root is required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[i + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else { fatalError("Use a private, unlinked .local acceptance directory") }
        self.root = root
        let urls = ["A.app", "B.app", "C.app"].map { root.appending(path: "Applications/" + $0) }
        let apps = urls.compactMap { AppScanner.read($0) }
        guard apps.count == 3, apps.allSatisfy({ $0.bundleID == "com.knollsoft.Rectangle" && ["2.0.3", "2.0.4"].contains($0.version) && $0.teamID != nil }) else { fatalError("Three isolated signed Rectangle copies are required") }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        preferences.set(false, forKey: "automaticChecksV1")
        preferences.set(false, forKey: "notificationsV1")
        let source = AcceptanceSource(); self.source = source
        let value = AppStore(preferences: preferences, installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal")),
            scanApplications: { _ in urls.compactMap { AppScanner.read($0) } }, checkApplication: { app, _ in await source.check(app) })
        value.apps = apps; value.selection = apps[0].id; value.section = .all
        value.monitoringTask = Task { }
        _store = State(initialValue: value)
    }
    var body: some Scene {
        WindowGroup("Upovi isolated batch acceptance", id: "main") {
            ContentView(store: store).frame(minWidth: 1000, minHeight: 650)
                .onChange(of: store.bulkUpdating) { _, active in
                    if !active && store.bulkHasRun { writeResult() }
                }
        }.defaultSize(width: 1240, height: 780)
        .commands {
            CommandMenu("Fixture") {
                Button("Repair fixture source") { Task { await source.repair() } }
            }
        }
        Settings { SettingsView(store: store) }
    }
    private func writeResult() {
        let apps = ["A.app", "B.app", "C.app"].compactMap { AppScanner.read(root.appending(path: "Applications/" + $0)) }
        let result: [String: Any] = ["installed": store.bulkCompletedCount, "failed": store.bulkFailedCount,
            "versions": apps.map(\.version), "builds": apps.map(\.build),
            "signaturesValid": apps.allSatisfy { (try? BundleVerifier.checkSignature(URL(fileURLWithPath: $0.path), like: $0)) != nil },
            "historyCount": store.batchHistory.count, "outcomes": store.bulkOutcomes.values.map { $0.status.rawValue }.sorted(),
            "isolatedCopiesOnly": true]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appending(path: "result-\(store.batchHistory.count).json"), options: .atomic)
        }
    }
}
