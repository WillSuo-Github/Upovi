import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class UserInitiatedUpdatesTests: XCTestCase {
    private func fixture() throws -> (AppStore, AppPreferences, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Applications/Fixture.app")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let app = InstalledApp(name: "Manual fixture", bundleID: "app.synthetic.manual", version: "1.0", path: path.path, teamID: "SYNTHETIC1")
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        preferences.set(true, forKey: "automaticChecksV1")
        // Model an existing installation that previously opted into automatic installation.
        let application = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app))
        let legacy = try JSONSerialization.data(withJSONObject: ["enabled": true,
            "grants": [["application": application, "channel": "stable"]], "attempts": [:], "history": []])
        preferences.set(legacy, forKey: "unattendedUpdatesV1")
        let reloaded = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        let installer = UpdateInstaller(journalDirectory: root.appending(path: "Journal"),
            downloads: DownloadCoordinator(storageURL: root.appending(path: "downloads.json")))
        let store = AppStore(preferences: reloaded, installer: installer, scanApplications: { _ in [app] }, revalidateSources: {}, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [.init(version: "2.0", source: "Fixture", isCommunity: false, url: nil,
                download: .init(url: URL(string: "https://example.invalid/app.dmg")!, sha256: String(repeating: "a", count: 64)))],
                note: "Fixture", status: .updates, checks: [.init(.homebrew, .checked)])
        })
        return (store, reloaded, root)
    }

    func testRetiredAutomaticPermissionsAreRemovedAndStayRemovedAfterRestart() throws {
        let (_, preferences, root) = try fixture()
        XCTAssertNil(preferences.data(forKey: "unattendedUpdatesV1"))
        let reloaded = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        XCTAssertNil(reloaded.data(forKey: "unattendedUpdatesV1"))
        XCTAssertTrue(reloaded.bool(forKey: "automaticChecksV1"), "Checks remain independent from installation")
    }

    private func assertNoInstallation(_ store: AppStore, root: URL) async {
        XCTAssertEqual(store.updateCount, 1)
        XCTAssertFalse(store.installing); XCTAssertFalse(store.bulkUpdating)
        XCTAssertNil(store.installationTask); XCTAssertNil(store.bulkTask)
        XCTAssertNil(store.preparedUpdate); XCTAssertNil(store.preparedPackage)
        XCTAssertTrue(store.transfers.isEmpty)
        let stream = await store.downloadCenter.coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        let downloads = await iterator.next()
        XCTAssertEqual(downloads?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Journal").path))
    }

    func testStartupDiscoversUpdatesWithoutDownloadingOrInstalling() async throws {
        let (store, _, root) = try fixture()
        store.startInitialCheck(); await store.checkTask?.value
        await assertNoInstallation(store, root: root)
    }

    func testScheduledSourceCheckCannotStartInstallation() async throws {
        let (store, _, root) = try fixture()
        store.refreshAll(); await store.checkTask?.value
        store.beginChecking(); await store.checkTask?.value
        await assertNoInstallation(store, root: root)
    }

    func testChannelChangesPersistWithoutAutomaticInstallationPermissions() async throws {
        let (store, preferences, root) = try fixture()
        store.refreshAll(); await store.checkTask?.value
        let app = try XCTUnwrap(store.apps.first)
        store.setReleaseChannel(.beta, for: app)
        XCTAssertEqual(store.releaseChannel(for: app), .beta)
        XCTAssertTrue(store.sourceResults.isEmpty)
        XCTAssertNil(preferences.data(forKey: "unattendedUpdatesV1"))
        let restarted = AppStore(preferences: AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false))
        XCTAssertEqual(restarted.releaseChannel(for: app), .beta)
        XCTAssertNil(restarted.installationTask); XCTAssertNil(restarted.bulkTask)
    }
}
