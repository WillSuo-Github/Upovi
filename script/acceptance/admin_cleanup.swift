// Explicit isolated native administrator acceptance. Not part of the shipping application.
import AppKit
import SwiftUI
import UpoviCore

final class CleanupDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct AdministratorCleanupAcceptance: App {
    @NSApplicationDelegateAdaptor(CleanupDelegate.self) private var delegate
    @State private var store: AppStore
    private let root: URL
    private let plan: AdministratorInstallPlan
    init() {
        guard let i = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(i + 1) else { fatalError("Explicit --root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[i + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else { fatalError("Use an unlinked private .local root") }
        self.root = root
        let target = URL(fileURLWithPath: "/Applications/Upovi Download Cleanup Acceptance.app")
        guard let current = AppScanner.read(target), current.bundleID == "com.knollsoft.Rectangle", ["2.0.3", "2.0.4"].contains(current.version) else { fatalError("Isolated signed fixture missing") }
        let file = root.appending(path: "plan.json")
        if FileManager.default.fileExists(atPath: file.path) {
            plan = try! JSONDecoder().decode(AdministratorInstallPlan.self, from: Data(contentsOf: file))
        } else {
            guard current.version == "2.0.3", let data = try? String(contentsOf: root.appending(path: "replacement.path"), encoding: .utf8) else { fatalError("Fresh old fixture required") }
            plan = .init(operation: .application, application: current, version: "2.0.4", build: "111", artifactPath: data)
            try! JSONEncoder().encode(plan).write(to: file, options: .atomic)
        }
        guard plan.application.path == target.path else { fatalError("Unexpected administrator target") }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key); preferences.set(false, forKey: "automaticChecksV1")
        preferences.set(false, forKey: "notificationsV1")
        let value = AppStore(preferences: preferences, scanApplications: { _ in AppScanner.read(target).map { [$0] } ?? [] })
        value.apps = [current]; value.selection = current.id; value.monitoringTask = Task { }
        value.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"))
        _store = State(initialValue: value)
    }
    var body: some Scene {
        WindowGroup("Upovi isolated cleanup acceptance", id: "main") {
            ContentView(store: store).frame(minWidth: 1000, minHeight: 650)
                .onChange(of: store.installing) { _, active in if !active { writeResult() } }
        }.defaultSize(width: 1240, height: 780)
        .commands {
            CommandMenu("Fixture") {
                Button("Prepare isolated administrator transaction") { prepare() }.disabled(store.installationBusy)
                Button("Verify restore is rejected after cleanup") { rejectRestore() }.disabled(store.installationBusy)
            }
        }
        Settings { SettingsView(store: store) }
    }
    private func prepare() {
        guard store.administrator.attempts.isEmpty else { return }
        store.installing = true
        Task {
            defer { store.installing = false }
            do { try await store.administrator.perform(plan) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func rejectRestore() {
        guard store.administrator.attempts.first?.cleanupComplete == true else { return }
        store.installing = true
        Task {
            defer { store.installing = false }
            var denied = false
            do {
                try await store.administrator.perform(.init(id: plan.id, operation: .restore, application: plan.application, version: plan.version, build: plan.build))
            } catch { denied = true }
            let result = ["restoreDeniedAfterCleanup": denied]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: root.appending(path: "restore-rejected.json"))
        }
    }
    private func writeResult() {
        guard let attempt = store.administrator.attempts.first else { return }
        let target = URL(fileURLWithPath: plan.application.path), current = AppScanner.read(target)
        let result: [String: Any] = ["transactionID": attempt.id.uuidString, "state": attempt.state,
            "cleanupComplete": attempt.cleanupComplete ?? false, "backupBytes": attempt.backupBytes ?? -1,
            "currentVersion": current?.version ?? "missing", "currentBuild": current?.build ?? "missing",
            "signatureValid": (try? BundleVerifier.checkSignature(target, like: plan.application)) != nil,
            "isolatedApplicationOnly": true]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "result.json"), options: .atomic)
    }
}
