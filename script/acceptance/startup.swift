// Isolated fresh-start acceptance using the production scanner, sources and views.
import AppKit
import SwiftUI
import UpoviCore

final class StartupDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct StartupAcceptance: App {
    @NSApplicationDelegateAdaptor(StartupDelegate.self) private var delegate
    @State private var store: AppStore
    private let root: URL

    init() {
        guard let index = CommandLine.arguments.firstIndex(of: "--root"),
              CommandLine.arguments.indices.contains(index + 1) else { fatalError("Explicit --root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else {
            fatalError("Use an unlinked private .local directory")
        }
        self.root = root
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        preferences.set(false, forKey: "automaticChecksV1")
        preferences.set(false, forKey: "notificationsV1")
        let coordinator = DownloadCoordinator(storageURL: root.appending(path: "downloads.json"))
        let store = AppStore(preferences: preferences,
                             installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: coordinator))
        store.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"), downloads: coordinator)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup("Upovi isolated startup acceptance", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 650)
                .onChange(of: store.apps.count) { _, _ in record() }
                .onChange(of: store.lastChecked) { _, _ in record() }
        }
        .defaultSize(width: 1240, height: 780)
    }

    private func record() {
        let result: [String: Any] = ["applications": store.apps.count, "sourceResults": store.sourceResults.count,
                                   "completedChecks": store.completedChecks, "checked": store.lastChecked != nil,
                                   "periodicChecksEnabled": store.automaticChecks, "p2pEnabled": store.networkEnabled]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appending(path: "startup-result.json"), options: .atomic)
        }
    }
}
