// Real official Mos copies and live sources; isolated preferences, downloads and installation history.
import AppKit
import SwiftUI
import UpoviCore

final class MosMigrationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MosMigrationAcceptanceApp: App {
    @NSApplicationDelegateAdaptor(MosMigrationDelegate.self) private var delegate
    @State private var store: AppStore
    init() {
        guard let index = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(index + 1) else { fatalError("Explicit --root is required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        let path = root.appending(path: "Applications/Mos.app")
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path,
              let app = AppScanner.read(path), ApplicationSourceCatalog.legacyMigration(for: app) != nil else { fatalError("Use the isolated official Mos 3.5.0 fixture") }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        preferences.set(false, forKey: "automaticChecksV1")
        preferences.set(false, forKey: "notificationsV1")
        let value = AppStore(preferences: preferences,
            installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloadCache: ArtifactDownloadCache(directory: root.appending(path: "Cache"))),
            scanApplications: { _ in AppScanner.read(path).map { [$0] } ?? [] },
            checkApplication: { app, _ in await UpdateChecker.check(app) })
        value.apps = [app]; value.section = .updates; value.selection = app.id
        value.monitoringTask = Task { }
        _store = State(initialValue: value)
    }
    var body: some Scene {
        WindowGroup("Upovi Mos migration acceptance") {
            ContentView(store: store).frame(minWidth: 1000, minHeight: 650)
                .task { store.refreshAll() }
        }.defaultSize(width: 1240, height: 780)
    }
}
