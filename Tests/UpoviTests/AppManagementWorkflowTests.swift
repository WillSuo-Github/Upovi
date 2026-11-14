import XCTest
import UpoviCore
@testable import Upovi

@MainActor private final class PermissionInstallState {
    var calls: [String] = []
    var shouldDeny = true
}

@MainActor final class AppManagementWorkflowTests: XCTestCase {
    private func preferences() throws -> AppPreferences {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-permission-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        prefs.set(false, forKey: GlobalP2PSettings.key)
        return prefs
    }

    private func denied() -> StoreInstallationError {
        .init(.init(stage: "appManagement", error: NSError(domain: NSCocoaErrorDomain, code: 513,
            userInfo: [NSLocalizedDescriptionKey: "token=PERMISSION_SECRET /Users/PRIVATE_OWNER/Private.app"])))
    }

    func testFirstLaunchCanBeSkippedAndDoesNotRequestAccessOrStartAnInstallation() throws {
        let prefs = try preferences(), store = AppStore(preferences: prefs)
        var settingsOpens = 0
        store.appManagementSettingsOpener = { settingsOpens += 1; return true }
        store.offerAppManagementIntroduction()
        XCTAssertEqual(store.appManagementGuide, .firstLaunch)
        store.dismissAppManagementGuide()
        store.offerAppManagementIntroduction()
        XCTAssertNil(store.appManagementGuide)
        let restarted = AppStore(preferences: prefs)
        restarted.offerAppManagementIntroduction()
        XCTAssertNil(restarted.appManagementGuide)
        XCTAssertEqual(settingsOpens, 0)
        XCTAssertNil(store.bulkTask); XCTAssertNil(store.installationTask)
        XCTAssertTrue(store.appManagementBlockedIDs.isEmpty)
        restarted.presentAppManagementHelp()
        XCTAssertEqual(restarted.appManagementGuide, .settings)
    }

    func testOpeningSettingsDoesNotClearDenialClaimConsentOrRetryAndFailureRemainsActionable() throws {
        let store = AppStore(preferences: try preferences())
        store.recordDiagnostic(.batchInstallation, appID: "/synthetic/private.app", error: denied())
        store.appManagementSettingsOpener = { false }
        XCTAssertFalse(store.openAppManagementSettings())
        store.appManagementSettingsOpener = { true }
        XCTAssertTrue(store.openAppManagementSettings())
        XCTAssertEqual(store.appManagementBlockedIDs, ["/synthetic/private.app"])
        XCTAssertNil(store.retryTask); XCTAssertNil(store.bulkTask); XCTAssertNil(store.installationTask)
        store.appManagementInstallerRevealer = { false }
        XCTAssertFalse(store.revealAppManagementInstaller())
        store.presentAppManagementHelp()
        XCTAssertEqual(store.appManagementGuide, .permissionRequired)
        store.dismissAppManagementGuide()
        store.presentAppManagementHelpAfterBatch()
        XCTAssertNil(store.appManagementGuide, "An unrelated batch must not repeat a previously dismissed permission sheet")
        store.presentAppManagementHelp()
        XCTAssertEqual(store.appManagementGuide, .permissionRequired, "Skipping guidance must not suppress future permission failures")
    }

    func testBatchAggregatesDenialsThenExplicitRetryRechecksOnlyBlockedAppsAndRequiresReview() async throws {
        let prefs = try preferences()
        let apps = (1...3).map { n in
            InstalledApp(name: "Permission fixture \(n)", bundleID: "app.synthetic.permission.\(n)", version: "1",
                path: "/Applications/Upovi Permission Fixture \(n).app", teamID: "SYNTHETIC1", isAppStore: true)
        }
        let candidates = Dictionary(uniqueKeysWithValues: apps.enumerated().map { i, app in
            (app.id, UpdateCandidate(version: "2", source: "App Store", isCommunity: false, url: nil, appStoreID: UInt64(12345 + i)))
        })
        let store = AppStore(preferences: prefs, scanApplications: { _ in apps }, revalidateSources: {}, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [candidates[app.id]!], note: "Fixture", status: .updates)
        })
        store.apps = apps
        store.sourceResults = Dictionary(uniqueKeysWithValues: apps.map {
            ($0.id, SourceResult(appID: $0.id, candidates: [candidates[$0.id]!], note: "Fixture", status: .updates))
        })
        store.makeInstallationAuthorizationBatch = { InstallationAuthorizationBatch(start: { _ in }) }
        let state = PermissionInstallState()
        let error = denied()
        store.installStoreUpdate = { _, app, _ in
            state.calls.append(app.id)
            XCTAssertNil(store.appManagementGuide, "Do not interrupt active batch jobs with a permission sheet")
            if state.shouldDeny && app.id != apps[2].id { throw error }
        }
        store.reviewAllUpdates(); store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(store.bulkFailedCount, 2); XCTAssertEqual(store.bulkCompletedCount, 1)
        XCTAssertEqual(store.appManagementBlockedIDs, Set(apps.prefix(2).map(\.id)))
        XCTAssertEqual(store.appManagementGuide, .permissionRequired)
        XCTAssertEqual(store.diagnosticEvents.first?.issue.kind, .permissionDenied)
        let restart = AppStore(preferences: prefs)
        XCTAssertEqual(restart.appManagementBlockedIDs, store.appManagementBlockedIDs)
        XCTAssertEqual(restart.appManagementRetryRecord?.retryIDs, store.appManagementBlockedIDs)
        XCTAssertNil(restart.retryTask); XCTAssertNil(restart.bulkTask)

        store.reviewAppManagementBlockedUpdates(); await store.retryTask?.value
        XCTAssertNil(store.appManagementGuide)
        XCTAssertTrue(store.bulkUpdatePresented); XCTAssertFalse(store.bulkHasRun)
        XCTAssertEqual(Set(store.bulkItems.map(\.id)), Set(apps.prefix(2).map(\.id)))
        XCTAssertEqual(state.calls.count, 3, "Rechecking and returning from Settings must never start an installation")
        XCTAssertEqual(store.appManagementBlockedIDs.count, 2, "Successful source checks are not permission evidence")

        state.shouldDeny = false
        store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(state.calls.count, 5)
        XCTAssertTrue(store.appManagementBlockedIDs.isEmpty)
        XCTAssertNil(store.appManagementGuide)
        XCTAssertTrue(AppStore(preferences: prefs).appManagementBlockedIDs.isEmpty)
        let snapshot = String(decoding: try store.diagnosticSnapshot().report(), as: UTF8.self)
        XCTAssertTrue(snapshot.contains("permissionDenied"))
        XCTAssertFalse(snapshot.contains("PERMISSION_SECRET")); XCTAssertFalse(snapshot.contains("PRIVATE_OWNER"))
    }

    func testOtherStoreErrorsAndCancelledWorkDoNotRequestAppManagement() throws {
        let store = AppStore(preferences: try preferences())
        store.recordDiagnostic(.batchInstallation, appID: "/synthetic/Full.app",
            error: StoreInstallationError(.init(stage: "appManagement", error: NSError(domain: NSCocoaErrorDomain, code: 640))))
        store.recordDiagnostic(.batchInstallation, appID: "/synthetic/Cancelled.app", error: CancellationError())
        store.presentAppManagementHelpAfterBatch()
        XCTAssertTrue(store.appManagementBlockedIDs.isEmpty); XCTAssertNil(store.appManagementGuide)
    }
    func testAccessVerificationShowsActualResultsWithoutRetryingUpdatesOrClearingFailures() async throws {
        let store = AppStore(preferences: try preferences())
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.store", version: "1.0", path: "/Applications/Fixture.app", teamID: "SYNTHETIC1", isAppStore: true)
        store.appManagementBlockedIDs = [app.id]
        store.appManagementAccessInventory = { [app] }
        store.appManagementAccessVerifier = { targets in
            XCTAssertEqual(targets, [app])
            var plan = AppStoreUpdatePlan(application: app, storeID: 1234, version: app.version, userID: 501)
            plan.permissionProbe = true
            return [.init(plan: plan, state: "accessVerified")]
        }
        store.installStoreUpdate = { _, _, _ in XCTFail("A permission check must never install") }
        store.verifyAppManagementAccess()
        for _ in 0..<100 where store.appManagementAccessChecking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.appManagementAccessChecks.count, 1)
        XCTAssertTrue(store.appManagementAccessChecks.allSatisfy(\.verified))
        XCTAssertTrue(store.appManagementBlockedAccessVerified)
        XCTAssertEqual(store.appManagementBlockedIDs, [app.id])
        store.appManagementSettingsOpener = { true }
        XCTAssertTrue(store.openAppManagementSettings())
        XCTAssertTrue(store.appManagementAccessChecks.isEmpty, "Opening Settings invalidates prior evidence")
        XCTAssertFalse(store.appManagementBlockedAccessVerified)
    }
    func testCancelledAccessVerificationNeverClaimsConsent() async throws {
        let store = AppStore(preferences: try preferences())
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.store", version: "1.0", path: "/Applications/Fixture.app", isAppStore: true)
        store.appManagementAccessInventory = { [app] }
        store.appManagementAccessVerifier = { _ in throw CancellationError() }
        store.verifyAppManagementAccess()
        for _ in 0..<100 where store.appManagementAccessChecking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.appManagementAccessChecks.isEmpty)
        XCTAssertNotNil(store.appManagementAccessError)
        XCTAssertNil(store.appManagementAccessCheckedAt)
    }

}
