import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class DownloadWorkflowTests: XCTestCase {
    private func preferences() throws -> AppPreferences {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-download-controls-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        prefs.set(false, forKey: GlobalP2PSettings.key); return prefs
    }
    private let original = InstalledApp(name: "Fixture", bundleID: "app.synthetic.retry", version: "1", path: "/synthetic/Retry.app", teamID: "SYNTHETIC")
    func testInterruptedDownloadRechecksFreshSourcesBeforePreparing() async throws {
        let app = original, coordinator = DownloadCoordinator()
        let store = AppStore(preferences: try preferences(), installer: UpdateInstaller(downloads: coordinator), scanApplications: { _ in [app] }, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [.init(version: "3", source: "Fresh", isCommunity: false, url: nil,
                download: .init(url: URL(string: "http://example.invalid/Forbidden.zip")!, sha256: String(repeating: "a", count: 64)))], note: "Fresh", status: .updates)
        })
        var history = DownloadRecord(app: app, targetVersion: "2"); history.state = .interrupted
        store.retryDownload(history); await store.retryTask?.value; await store.installationTask?.value
        let records = await coordinator.snapshot()
        XCTAssertEqual(records.first?.targetVersion, "3")
        XCTAssertFalse(store.installationConfirmation)
        XCTAssertFalse(store.installing)
    }
    func testChangedIdentityAndIgnoredApplicationsCannotResumeHistoricalConsent() async throws {
        for ignored in [false, true] {
            let app = InstalledApp(name: original.name, bundleID: original.bundleID, version: "1", path: original.path, teamID: ignored ? original.teamID : "DIFFERENT")
            let coordinator = DownloadCoordinator()
            let store = AppStore(preferences: try preferences(), installer: UpdateInstaller(downloads: coordinator), scanApplications: { _ in [app] }, checkApplication: { app, _ in
                .init(appID: app.id, candidates: [.init(version: "3", source: "Fresh", isCommunity: false, url: nil)], note: "Fresh", status: .updates)
            })
            if ignored { store.ignored.insert(app.bundleID) }
            var record = DownloadRecord(app: original, targetVersion: "2"); record.state = .interrupted
            store.retryDownload(record); await store.retryTask?.value
            XCTAssertNil(store.installationTask); XCTAssertNotNil(store.errorMessage)
            let records = await coordinator.snapshot(); XCTAssertTrue(records.isEmpty)
        }
    }
}
