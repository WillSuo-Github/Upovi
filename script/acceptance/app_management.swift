import AppKit
import SwiftUI
import UpoviCore

final class PermissionAcceptanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Isolated permission UI acceptance. No real inventory, installation or authorization runs.
@main struct PermissionAcceptance: App {
    @NSApplicationDelegateAdaptor(PermissionAcceptanceDelegate.self) private var delegate
    @State private var store: AppStore

    init() {
        guard let index = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(index + 1) else { exit(0) }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else { exit(0) }
        setenv("UPOVI_LOG_DIRECTORY", root.appending(path: "Logs").path, 1)
        let prefs = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        prefs.set(false, forKey: GlobalP2PSettings.key); prefs.set(false, forKey: "automaticChecksV1"); prefs.set(false, forKey: "notificationsV1")
        let apps = (1...2).map { index in
            InstalledApp(name: "Permission Fixture \(index)", bundleID: "app.synthetic.permissions.\(index)", version: "1",
                         path: "/Applications/Upovi Permission Fixture \(index).app", teamID: "SYNTHETIC1", isAppStore: true)
        }
        let candidates = Dictionary(uniqueKeysWithValues: apps.enumerated().map { index, app in
            (app.id, UpdateCandidate(version: "2", source: "App Store", isCommunity: false, url: nil, appStoreID: UInt64(12345 + index)))
        })
        let downloads = DownloadCoordinator(storageURL: root.appending(path: "downloads.json"))
        let value = AppStore(preferences: prefs, installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: downloads),
            scanApplications: { _ in apps }, revalidateSources: {}, checkApplication: { app, _ in
                .init(appID: app.id, candidates: [candidates[app.id]!], note: "Offline fixture", status: .updates)
            })
        value.apps = apps; value.section = .updates; value.monitoringTask = Task { }
        value.sourceResults = Dictionary(uniqueKeysWithValues: apps.map {
            ($0.id, SourceResult(appID: $0.id, candidates: [candidates[$0.id]!], note: "Offline fixture", status: .updates))
        })
        value.makeInstallationAuthorizationBatch = { InstallationAuthorizationBatch(start: { _ in }) }
        value.installStoreUpdate = { _, _, _ in
            throw StoreInstallationError(.init(stage: "appManagement", error: NSError(domain: NSCocoaErrorDomain, code: 513,
                userInfo: [NSLocalizedDescriptionKey: "token=PERMISSION_NATIVE_SECRET /Users/PRIVATE_OWNER/App.app"])))
        }
        value.appManagementSettingsOpener = { true }
        _store = State(initialValue: value)
    }

    var body: some Scene {
        WindowGroup("Upovi isolated access help acceptance", id: "main") {
            ContentView(store: store)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("Offline permission fixture — no installed apps are changed").font(.caption)
                        Spacer()
                        Button("Open Access Help") { store.presentAppManagementHelp() }
                        Button("Simulate Denied Updates") { store.reviewAllUpdates() }
                            .disabled(store.operationBusy)
                        Button("Allow Next Updates") { store.installStoreUpdate = { _, _, _ in } }
                    }.padding(10)
                }
        }.defaultSize(width: 1240, height: 780)
        Settings { SettingsView(store: store) }
    }
}
