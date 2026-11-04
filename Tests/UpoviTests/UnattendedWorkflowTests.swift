import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class UnattendedWorkflowTests: XCTestCase {
    private func fixture() throws -> (AppStore, InstalledApp, UpdateCandidate, AppPreferences, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings.plist"), prefs = AppPreferences(url: file, migrateUserDefaults: false)
        prefs.set(false, forKey: GlobalP2PSettings.key)
        let app = InstalledApp(name: "Automatic fixture", bundleID: "app.synthetic.automatic", version: "1.0", path: "/Applications/Automatic Fixture.app", teamID: "SYNTHETIC1")
        let candidate = UpdateCandidate(version: "2.0", source: "Fixture", isCommunity: false, url: nil,
            download: .init(url: URL(string: "https://example.com/app.dmg")!, sha256: String(repeating: "a", count: 64)))
        let store = AppStore(preferences: prefs, scanApplications: { _ in [app] }, revalidateSources: {}, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [candidate], note: "", status: .updates, checks: [.init(.homebrew, .checked)])
        })
        store.apps = [app]; store.lastChecked = Date()
        store.unattendedWritable = { _ in true }; store.runningUpdateApplications = { _ in [] }
        return (store, app, candidate, prefs, file)
    }
    func testDefaultOffAndPerApplicationConsentSurviveRestartButChannelChangesRevokeIt() throws {
        let (store, app, _, prefs, _) = try fixture()
        XCTAssertFalse(store.unattendedState.enabled); XCTAssertTrue(store.unattendedState.grants.isEmpty)
        store.beginUnattendedUpdates(); XCTAssertNil(store.unattendedTask)
        store.setUnattendedAllowed(true, for: app); XCTAssertTrue(store.setUnattendedEnabled(true))
        let restarted = AppStore(preferences: prefs)
        XCTAssertNotNil(restarted.unattendedState.grant(for: app, channel: .stable))
        restarted.setReleaseChannel(.beta, for: app)
        XCTAssertTrue(restarted.unattendedState.grants.isEmpty)
        let again = AppStore(preferences: prefs)
        XCTAssertEqual(again.releaseChannel(for: app), .beta)
        XCTAssertTrue(again.unattendedState.grants.isEmpty)
    }
    func testAutomaticInstallPersistsBeforeCommitAndRecordsSuccessWithoutReviewOrAuthorization() async throws {
        let (store, app, _, prefs, _) = try fixture()
        store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
        var calls = 0
        store.unattendedOperation = { item, commit in
            XCTAssertEqual(item.application.id, app.id)
            try commit()
            let persisted = try JSONDecoder().decode(UnattendedUpdateState.self, from: XCTUnwrap(prefs.data(forKey: "unattendedUpdatesV1")))
            XCTAssertEqual(persisted.history.first?.phase, .installing)
            calls += 1
        }
        store.beginUnattendedUpdates(); await store.unattendedTask?.value
        XCTAssertEqual(calls, 1); XCTAssertEqual(store.unattendedState.history.first?.phase, .installed)
        XCTAssertNotNil(store.unattendedState.history.first?.finishedAt)
        XCTAssertFalse(store.installationBusy); XCTAssertFalse(store.bulkUpdatePresented); XCTAssertFalse(store.installationConfirmation)
        XCTAssertNil(store.errorMessage)
    }
    func testOpeningApplicationDuringPreparationDefersWithoutQuittingOrInstalling() async throws {
        let (store, app, _, _, _) = try fixture()
        store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
        var installed = false, quits = 0
        store.quitUpdateApplication = { _ in quits += 1 }
        store.unattendedOperation = { _, checkpoint in
            store.runningUpdateApplications = { _ in [app] }
            try checkpoint(); installed = true
        }
        store.beginUnattendedUpdates(); await store.unattendedTask?.value
        XCTAssertFalse(installed); XCTAssertEqual(quits, 0)
        XCTAssertEqual(store.unattendedState.history.first?.phase, .deferred)
    }
    func testRevokingMasterConsentDuringPreparationPreventsCommit() async throws {
        let (store, app, _, _, _) = try fixture()
        store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
        var installed = false
        store.unattendedOperation = { _, checkpoint in
            store.setUnattendedEnabled(false)
            try checkpoint(); installed = true
        }
        store.beginUnattendedUpdates(); await store.unattendedTask?.value
        XCTAssertFalse(installed); XCTAssertFalse(store.unattendedState.enabled)
        XCTAssertEqual(store.unattendedState.history.first?.phase, .cancelled)
    }
    func testIgnoredSkippedRunningAndUnwritableApplicationsNeverStartPreparation() async throws {
        for mode in 0..<4 {
            let (store, app, candidate, _, _) = try fixture()
            store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
            switch mode {
            case 0: store.ignored = [app.bundleID]
            case 1: store.setSkipped(candidate, app: app, skipped: true)
            case 2: store.runningUpdateApplications = { _ in [app] }
            default: store.unattendedWritable = { _ in false }
            }
            var calls = 0; store.unattendedOperation = { _, _ in calls += 1 }
            store.beginUnattendedUpdates(); await store.unattendedTask?.value
            XCTAssertEqual(calls, 0); XCTAssertTrue(store.unattendedState.history.isEmpty)
        }
    }
    func testHistoryWriteFailurePreventsPreparation() async throws {
        let (store, app, _, _, file) = try fixture()
        store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var calls = 0; store.unattendedOperation = { _, _ in calls += 1 }
        store.beginUnattendedUpdates(); await store.unattendedTask?.value
        XCTAssertEqual(calls, 0); XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.unattendedState.history.isEmpty)
    }
    func testOneFailureDoesNotStopOtherApplicationsAndIsNotImmediatelyRetried() async throws {
        let (_, app, candidate, prefs, _) = try fixture()
        let other = InstalledApp(name: "Other", bundleID: "app.synthetic.other", version: "1.0", path: "/Applications/Other.app", teamID: "SYNTHETIC1")
        let apps = [app, other]
        let store = AppStore(preferences: prefs, scanApplications: { _ in apps }, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [candidate], note: "", status: .updates)
        })
        store.apps = apps; store.lastChecked = Date(); store.unattendedWritable = { _ in true }; store.runningUpdateApplications = { _ in [] }
        for app in apps { store.setUnattendedAllowed(true, for: app) }
        store.setUnattendedEnabled(true)
        var committed = 0
        store.unattendedOperation = { item, checkpoint in
            if item.id == app.id { throw PeerError.invalid("Synthetic download failure") }
            try checkpoint(); committed += 1
        }
        store.beginUnattendedUpdates(); await store.unattendedTask?.value
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(Set(store.unattendedState.history.map(\.phase)), [.installed, .failed])
        XCTAssertNil(store.errorMessage)
        store.beginUnattendedUpdates(); await store.unattendedTask?.value
        XCTAssertEqual(committed, 1); XCTAssertEqual(store.unattendedState.history.count, 2)
    }
    func testManualRefreshDoesNotAutoInstallAndExplicitScheduledRunDoes() async throws {
        let (store, app, _, _, _) = try fixture()
        store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
        var calls = 0; store.unattendedOperation = { _, checkpoint in try checkpoint(); calls += 1 }
        store.refreshAll(); await store.checkTask?.value
        XCTAssertEqual(calls, 0); XCTAssertNil(store.unattendedTask)
        store.refreshAll(allowUnattended: true); await store.checkTask?.value; await store.unattendedTask?.value
        XCTAssertEqual(calls, 1)
    }
    func testStartupFreshScanCanRunPreviouslyAuthorizedUpdates() async throws {
        let (store, app, _, _, _) = try fixture()
        store.setUnattendedAllowed(true, for: app); store.setUnattendedEnabled(true)
        store.apps = []
        var calls = 0; store.unattendedOperation = { _, checkpoint in try checkpoint(); calls += 1 }
        store.startInitialCheck(); await store.checkTask?.value; await store.unattendedTask?.value
        XCTAssertEqual(calls, 1); XCTAssertEqual(store.unattendedState.history.first?.phase, .installed)
    }
    func testInterruptedAndInvalidStoredPermissionsCannotResumeAnInstallation() async throws {
        let (store, app, candidate, prefs, _) = try fixture()
        var state = UnattendedUpdateState(); state.enabled = true
        state.grants = [try .init(application: app, channel: .stable)]
        state.record(.init(app: app, candidate: candidate, channel: .stable))
        prefs.set(try JSONEncoder().encode(state), forKey: "unattendedUpdatesV1")
        let recovered = AppStore(preferences: prefs)
        XCTAssertEqual(recovered.unattendedState.history.first?.phase, .interrupted)
        XCTAssertNotNil(recovered.unattendedState.attempts[app.id])
        state.grants.append(state.grants[0])
        prefs.set(try JSONEncoder().encode(state), forKey: "unattendedUpdatesV1")
        let invalid = AppStore(preferences: prefs)
        XCTAssertFalse(invalid.unattendedState.enabled); XCTAssertTrue(invalid.unattendedState.grants.isEmpty)
        XCTAssertFalse(store.unattendedState.enabled)
    }
}
