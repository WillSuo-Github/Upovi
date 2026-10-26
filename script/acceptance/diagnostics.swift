// Explicit synthetic, offline diagnostic-export acceptance. No inventory, downloads or root operations.
import AppKit
import SwiftUI
import UpoviCore

final class DiagnosticsDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct DiagnosticsAcceptance: App {
    @NSApplicationDelegateAdaptor(DiagnosticsDelegate.self) private var delegate
    @State private var store: AppStore
    init() {
        guard let index = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(index + 1) else { fatalError("Explicit --root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else { fatalError("Use a private unlinked .local directory") }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key); preferences.set(false, forKey: "automaticChecksV1"); preferences.set(false, forKey: "notificationsV1")
        let app = InstalledApp(name: "Private diagnostic fixture", bundleID: "app.synthetic.diagnostics", version: "1.0", path: root.appending(path: "Secret.app").path)
        let value = AppStore(preferences: preferences, installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal")), scanApplications: { _ in [app] })
        value.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"))
        value.apps = [app]; value.selection = app.id; value.monitoringTask = Task { }
        value.sourceResults = [app.id: .init(appID: app.id, candidates: [], note: "TOP_SECRET_RAW_ERROR https://private.invalid/?token=TOP_SECRET_TOKEN", status: .failed,
                                           checks: [.init(.github, .failed, error: HTTPStatusError(statusCode: 429))])]
        value.recordDiagnostic(.preparation, appID: app.id, error: PeerError.invalid("TOP_SECRET_RAW_ERROR"))
        _store = State(initialValue: value)
    }
    var body: some Scene {
        WindowGroup("Upovi isolated diagnostics acceptance", id: "main") { ContentView(store: store) }.defaultSize(width: 1240, height: 780)
        Settings { SettingsView(store: store) }
    }
}
