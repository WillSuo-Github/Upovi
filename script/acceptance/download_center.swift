// Synthetic offline native controller acceptance. No real applications or installation.
import AppKit
import SwiftUI
@testable import UpoviCore

actor SyntheticTransfer {
    var retained: Int64 = 0
    var finishNow = false
    func reset() { retained = 0; finishNow = false }
    func complete() { finishNow = true }
    func run(_ destination: URL, phase: @Sendable (ArtifactDownloadPhase) -> Void,
             resume: @Sendable (Int64) -> Void, progress: @Sendable (Int64, Int64) -> Void) async throws {
        if retained > 0 { resume(retained) }
        phase(.downloading)
        while retained < 5_000_000 && !finishNow {
            try await Task.sleep(for: .milliseconds(100)); retained += 16_384; progress(retained, 5_000_000)
        }
        try Task.checkCancellation(); phase(.verifying)
        try Data("Synthetic verified archive".utf8).write(to: destination)
    }
}
final class DownloadDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct DownloadCenterAcceptance: App {
    @NSApplicationDelegateAdaptor(DownloadDelegate.self) private var delegate
    @State private var store: AppStore
    private let coordinator: DownloadCoordinator
    private let transfer: SyntheticTransfer
    private let root: URL
    private let app: InstalledApp
    init() {
        guard let index = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(index + 1) else { fatalError("Explicit --root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else { fatalError("Use an unlinked private .local directory") }
        self.root = root
        let app = InstalledApp(name: "Download Acceptance", bundleID: "app.synthetic.download", version: "1", path: root.appending(path: "Fixture.app").path, teamID: "SYNTHETIC")
        self.app = app
        let transfer = SyntheticTransfer(); self.transfer = transfer
        let coordinator = DownloadCoordinator(storageURL: root.appending(path: "tasks.json")) { _, _, destination, phase, resume, progress in
            try await transfer.run(destination, phase: phase, resume: resume, progress: progress)
        }; self.coordinator = coordinator
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key); preferences.set(false, forKey: "automaticChecksV1"); preferences.set(false, forKey: "notificationsV1")
        let store = AppStore(preferences: preferences, installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: coordinator),
                             scanApplications: { _ in [app] }, checkApplication: { app, _ in .init(appID: app.id, candidates: [], note: "Synthetic offline fixture", status: .current) })
        store.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"), downloads: coordinator)
        store.apps = [app]; store.section = .downloads; store.monitoringTask = Task { }
        _store = State(initialValue: store)
    }
    var body: some Scene {
        WindowGroup("Upovi isolated download acceptance", id: "main") { ContentView(store: store) }.defaultSize(width: 1240, height: 780)
        .commands {
            CommandMenu("Fixture") {
                Button("Start synthetic download") {
                    Task { await transfer.reset(); try? await coordinator.download(.init(url: URL(string: "https://example.invalid/Fixture.zip")!, sha256: String(repeating: "a", count: 64)), app: app, targetVersion: "2", to: root.appending(path: "Output-\(UUID().uuidString).zip"), progress: { _, _ in }) }
                }
                .disabled(store.downloadCenter.records.contains { $0.state.active })
                Button("Disconnect fixture network") { Task { await coordinator.setOnline(false) } }
                Button("Reconnect fixture network") { Task { await coordinator.setOnline(true) } }
                Button("Complete synthetic transfer") { Task { await transfer.complete() } }
            }
        }
        Settings { SettingsView(store: store) }
    }
}
