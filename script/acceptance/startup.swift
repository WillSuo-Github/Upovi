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
              CommandLine.arguments.indices.contains(index + 1) else {
            // Launch Services and the crash dialog's Reopen action do not preserve CLI arguments.
            // This fixture has no default authority or inventory; end an unconfigured launch normally.
            exit(0)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path else {
            fputs("Use an unlinked private .local directory\n", stderr)
            exit(0)
        }
        self.root = root
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        preferences.set(false, forKey: "automaticChecksV1")
        preferences.set(false, forKey: "notificationsV1")
        let coordinator = DownloadCoordinator(storageURL: root.appending(path: "downloads.json"))
        let preview = CommandLine.arguments.contains("--quit-preview")
        let toolsPreview = CommandLine.arguments.contains("--tools-preview")
        let completionPreview = CommandLine.arguments.contains("--completion-preview")
        let allSucceeded = CommandLine.arguments.contains("--all-succeeded")
        let selected: String? = {
            guard let index = CommandLine.arguments.firstIndex(of: "--store-app"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
            return CommandLine.arguments[index + 1]
        }()
        let fixtures = (1...2).map { index in
            InstalledApp(name: "Running App \(index)", bundleID: "app.synthetic.store\(index)", version: "1", path: "/Applications/Upovi Synthetic Store \(index).app", teamID: "SYNTHETIC1", isAppStore: true)
        }
        let completionApps = ["zoom.us", "Completed App A", "Completed App B"].enumerated().map { index, name in
            InstalledApp(name: name, bundleID: "app.synthetic.completion\(index)", version: "1", path: "/Applications/Upovi Completion Fixture \(index).app", teamID: "SYNTHETIC1", isAppStore: true)
        } + [InstalledApp(name: "Unity", bundleID: "app.synthetic.manual", version: "1", path: "/Applications/Unity/Hub/Editor/Fixture/Unity.app", teamID: "SYNTHETIC1")]
        let store = AppStore(preferences: preferences,
            installer: UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: coordinator),
            scanApplications: { roots in
                if completionPreview { return completionApps }
                if toolsPreview { return [] }
                if preview { return fixtures }
                if let selected { return AppScanner.read(URL(fileURLWithPath: selected)).map { [$0] } ?? [] }
                return await Task.detached { AppScanner.scan(roots: roots) }.value
            }, checkApplication: { app, _ in
                if completionPreview {
                    return .init(appID: app.id, candidates: [.init(version: "2", source: "Offline fixture", isCommunity: false, url: nil, appStoreID: app.isAppStore ? 12345 : nil)], note: "Offline completion fixture", status: .updates)
                }
                if preview { return .init(appID: app.id, candidates: [.init(version: "2", source: "App Store", isCommunity: false, url: nil, appStoreID: 12345)], note: "Offline quit confirmation fixture", status: .updates) }
                return await UpdateChecker.check(app)
            })
        if completionPreview {
            let sources: [ToolSource] = [.homebrew, .npm, .uv, .rustup]
            store.toolLocations = Dictionary(uniqueKeysWithValues: sources.map { ($0, URL(fileURLWithPath: "/fixture/" + $0.executableName)) })
            store.enabledToolSources = Set(sources)
            store.checkToolSource = { source, _ in .init(source: source, installed: ["fixture-tool":"1"], updates: source == .npm ? [.init(name: "fixture-tool", installed: "1", available: "2")] : []) }
            store.updateToolSource = { source, _, _ in .init(source: source, installed: ["fixture-tool":"2"], updates: []) }
            store.runningUpdateApplications = { _ in [] }
            store.installStoreUpdate = { _, app, _ in
                if app.name == "zoom.us" && !allSucceeded { throw InstallationSpaceError(required: 6_000_000_000, available: 5_000_000_000) }
            }
            store.makeInstallationAuthorizationBatch = {
                InstallationAuthorizationBatch { _, _ in throw PeerError.invalid("Offline fixture must never authorize") }
            }
        } else if toolsPreview {
            var environment = ProcessInfo.processInfo.environment
            environment["NPM_CONFIG_PREFIX"] = root.appending(path: "npm-prefix").path
            environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
            let isolatedEnvironment = environment
            let service = ToolSourceService(runner: { command in
                try await ProcessCommand().run(command.executable.path, command.arguments,
                    timeoutSeconds: 180, environment: isolatedEnvironment, successCodes: command.successCodes,
                    currentDirectory: root)
            })
            store.toolLocations = [.npm: URL(fileURLWithPath: "/opt/homebrew/bin/npm")]
            store.enabledToolSources = [.npm]
            store.checkToolSource = { source, executable in try await service.check(source, executable: executable) }
            store.updateToolSource = { source, executable, context in try await service.update(source, executable: executable, expectedContext: context) }
        } else if preview {
            store.runningUpdateApplications = { $0 }
            store.quitUpdateApplication = { _ in }
            store.makeInstallationAuthorizationBatch = {
                InstallationAuthorizationBatch { command, _ in try await ProcessCommand().run("/bin/sh", ["-c", command]) }
            }
            store.installStoreUpdate = { _, _, authorization in _ = try await authorization.run("printf installed", nil) }
        } else if selected != nil {
            store.installStoreUpdate = { candidate, app, authorization in
                try await AppStoreInstallationService(directory: root.appending(path: "StoreAttempts")).perform(candidate, app: app, authorize: authorization)
            }
        }
        store.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"), downloads: coordinator)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup("Upovi isolated startup acceptance", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 650)
                .onChange(of: store.apps.count) { _, _ in record() }
                .onChange(of: store.lastChecked) { _, _ in
                    record()
                    if CommandLine.arguments.contains("--review") { store.reviewAllUpdates() }
                }
                .onChange(of: store.bulkQuitPresented) { _, _ in record() }
                .onChange(of: store.bulkUpdating) { _, _ in record() }
        }
        .defaultSize(width: 1240, height: 780)
        Settings { SettingsView(store: store) }
    }

    private func record() {
        let result: [String: Any] = ["applications": store.apps.count, "sourceResults": store.sourceResults.count,
                                   "completedChecks": store.completedChecks, "checked": store.lastChecked != nil,
                                   "periodicChecksEnabled": store.automaticChecks, "p2pEnabled": store.networkEnabled,
                                   "quitConfirmation": store.bulkQuitPresented, "succeeded": store.bulkCompletedCount, "failed": store.bulkFailedCount,
                                   "outcomes": store.bulkOutcomes.values.map { ["app": $0.item.application.name, "status": $0.status.rawValue, "detail": $0.detail] },
                                   "toolHistory": store.toolHistory.map { ["source": $0.source.rawValue, "status": $0.state.rawValue, "detail": $0.detail] }]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appending(path: "startup-result.json"), options: .atomic)
        }
    }
}
