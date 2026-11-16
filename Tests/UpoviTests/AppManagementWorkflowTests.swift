import XCTest
import UpoviCore
@testable import Upovi

@MainActor private final class PermissionInstallState {
    var calls: [String] = []
    var shouldDeny = true
    var releaseMaintenance: CheckedContinuation<Void, Never>?
    var maintenanceCalls = 0
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

    func testFreshLaunchAndLegacyFailureHistoryNeverPresentPermissionSetup() async throws {
        let prefs = try preferences()
        prefs.set(false, forKey: "appManagementGuideSeenV1")
        prefs.set(["/Applications/Old Failure.app"], forKey: AppStore.appManagementBlockedKey)
        let store = AppStore(preferences: prefs, scanApplications: { _ in [] }, revalidateSources: {})
        var settingsOpens = 0
        store.appManagementSettingsOpener = { settingsOpens += 1; return true }
        store.startInitialCheck(); await store.checkTask?.value
        XCTAssertNil(store.appManagementGuide)
        XCTAssertNil(store.appManagementRetryRecord, "Old probe denials without failed updates cannot produce a retry banner")
        XCTAssertNil(store.bulkTask); XCTAssertNil(store.installationTask)
        XCTAssertEqual(settingsOpens, 0)
        let restarted = AppStore(preferences: prefs, scanApplications: { _ in [] }, revalidateSources: {})
        restarted.startInitialCheck(); await restarted.checkTask?.value
        XCTAssertNil(restarted.appManagementGuide)
        store.presentAppManagementHelp()
        XCTAssertEqual(store.appManagementGuide, .settings, "Only the explicit help action opens the sheet")
    }

    func testOpeningSettingsDoesNotClaimConsentClearHistoryOrStartWork() throws {
        let prefs = try preferences(), store = AppStore(preferences: prefs)
        store.recordDiagnostic(.batchInstallation, appID: "/synthetic/private.app", error: denied())
        XCTAssertNil(store.appManagementGuide)
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.store", version: "1",
            path: "/Applications/Fixture.app", isAppStore: true)
        store.recordSuccessfulAppManagementAccess(app)
        store.appManagementSettingsOpener = { false }
        XCTAssertFalse(store.openAppManagementSettings())
        store.appManagementSettingsOpener = { true }
        XCTAssertTrue(store.openAppManagementSettings())
        XCTAssertEqual(store.appManagementBlockedIDs, ["/synthetic/private.app"])
        XCTAssertEqual(AppStore(preferences: prefs).appManagementAccessChecks.map(\.id), [app.id], "Opening Settings does not erase factual write history")
        XCTAssertNil(store.retryTask); XCTAssertNil(store.bulkTask); XCTAssertNil(store.installationTask)
        store.appManagementInstallerRevealer = { false }
        XCTAssertFalse(store.revealAppManagementInstaller())
        store.presentAppManagementHelp()
        XCTAssertEqual(store.appManagementGuide, .settings)
        store.dismissAppManagementGuide()
        XCTAssertNil(store.appManagementGuide)
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
        XCTAssertNil(store.appManagementGuide, "A write denial is not proof that a privacy switch is off and must not open a setup modal")
        store.presentAppManagementHelp()
        XCTAssertEqual(store.appManagementGuide, .accessDenied)
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
        let relaunched = AppStore(preferences: prefs)
        XCTAssertTrue(Set(relaunched.appManagementAccessChecks.map(\.id)).isSuperset(of: Set(apps.prefix(2).map(\.id))),
                      "Both successfully retried targets must retain access evidence regardless of earlier concurrent denial order")
        XCTAssertTrue(relaunched.appManagementAccessChecks.allSatisfy(\.verified))
        XCTAssertNil(relaunched.appManagementGuide)
        XCTAssertNil(relaunched.bulkTask, "Restoring past access must not authorize or install updates")
        let snapshot = String(decoding: try store.diagnosticSnapshot().report(), as: UTF8.self)
        XCTAssertTrue(snapshot.contains("permissionDenied"))
        XCTAssertFalse(snapshot.contains("PERMISSION_SECRET")); XCTAssertFalse(snapshot.contains("PRIVATE_OWNER"))
    }

    func testOtherStoreErrorsAndCancelledWorkDoNotRequestAppManagement() throws {
        let store = AppStore(preferences: try preferences())
        store.recordDiagnostic(.batchInstallation, appID: "/synthetic/Full.app",
            error: StoreInstallationError(.init(stage: "appManagement", error: NSError(domain: NSCocoaErrorDomain, code: 640))))
        store.recordDiagnostic(.batchInstallation, appID: "/synthetic/Cancelled.app", error: CancellationError())
        XCTAssertTrue(store.appManagementBlockedIDs.isEmpty); XCTAssertNil(store.appManagementGuide)
    }

    func testNewDenialInvalidatesPersistedSuccessWithoutClaimingPermissionRevocation() throws {
        let prefs = try preferences(), store = AppStore(preferences: prefs)
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.store", version: "1", path: "/Applications/Fixture.app", isAppStore: true)
        store.recordSuccessfulAppManagementAccess(app)
        XCTAssertTrue(AppStore(preferences: prefs).appManagementAccessChecks.allSatisfy(\.verified))
        store.recordAppManagementBlock(appID: app.id, error: denied())
        let restarted = AppStore(preferences: prefs)
        XCTAssertTrue(restarted.appManagementAccessChecks.isEmpty)
        XCTAssertEqual(restarted.appManagementBlockedIDs, [app.id])
        XCTAssertNil(restarted.appManagementAccessCheckedAt)
    }

    func testStartupBackupMaintenanceBlocksUpdateAdmissionAndReleasesAfterCompletionOrFailure() async throws {
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.maintenance", version: "1",
            path: "/Applications/Upovi Maintenance Fixture.app", teamID: "SYNTHETIC1", isAppStore: true)
        let candidate = UpdateCandidate(version: "2", source: "App Store", isCommunity: false, url: nil, appStoreID: 12345)
        let store = AppStore(preferences: try preferences(), automaticBackupMaintenanceEnabled: true, scanApplications: { _ in [app] })
        store.apps = [app]
        store.sourceResults = [app.id: .init(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)]
        let state = PermissionInstallState()
        store.performBackupMaintenance = {
            let shouldWait = await MainActor.run {
                state.maintenanceCalls += 1
                return state.maintenanceCalls == 1
            }
            guard shouldWait else { return BackupMaintenanceReport() }
            await withCheckedContinuation { continuation in
                Task { @MainActor in state.releaseMaintenance = continuation }
            }
            return BackupMaintenanceReport()
        }
        let maintenance = Task { await store.maintainApplicationBackups() }
        for _ in 0..<100 where state.releaseMaintenance == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(state.releaseMaintenance)
        XCTAssertTrue(store.installationBusy)
        store.reviewAllUpdates()
        XCTAssertFalse(store.bulkUpdatePresented)
        store.prepareInstallation(candidate, app: app)
        XCTAssertNil(store.installationTask)
        await store.maintainApplicationBackups(force: true)
        XCTAssertEqual(state.maintenanceCalls, 1, "Maintenance must not reenter while its first run is suspended")
        state.releaseMaintenance?.resume(); state.releaseMaintenance = nil
        await maintenance.value
        XCTAssertFalse(store.installationBusy)
        // A genuine maintenance failure must also release the gate and stay actionable.
        store.performBackupMaintenance = { throw URLError(.cannotWriteToFile) }
        await store.maintainApplicationBackups(force: true)
        XCTAssertFalse(store.installationBusy)
        XCTAssertEqual(store.diagnosticEvents.first?.stage, .backupCleanup)
        store.reviewAllUpdates()
        XCTAssertTrue(store.bulkUpdatePresented)
        store.performBackupMaintenance = { BackupMaintenanceReport() }
        store.makeInstallationAuthorizationBatch = { InstallationAuthorizationBatch(start: { _ in }) }
        store.installStoreUpdate = { _, _, _ in state.calls.append(app.id) }
        store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(state.calls, [app.id])
        XCTAssertEqual(store.bulkCompletedCount, 1)
        XCTAssertTrue(store.appManagementBlockedIDs.isEmpty)
    }

    func testAccessVerificationSubmitsProbeOnlyPlansThroughOneBatchSessionAndPreservesDenials() async throws {
        let apps = (1...2).map { index in
            InstalledApp(name: "Fixture \(index)", bundleID: "app.synthetic.probe.\(index)", version: "1",
                path: "/Applications/Upovi Probe Fixture \(index).app", teamID: "SYNTHETIC1", isAppStore: true)
        }
        let plans = apps.enumerated().map { index, app in
            var plan = AppStoreUpdatePlan(application: app, storeID: UInt64(12345 + index), version: app.version, userID: 501)
            plan.permissionProbe = true
            return plan
        }
        var starts = 0, submissions = 0
        let batch = InstallationAuthorizationBatch(permissionProbe: true, start: { items in
            starts += 1
            XCTAssertEqual(items.map(\.application), apps)
        }, submit: { request in
            guard case .store(let plan) = request else { XCTFail("Only Store probes are allowed"); throw CancellationError() }
            XCTAssertEqual(plan.permissionProbe, true)
            XCTAssertNil(plan.receiptRecovery)
            var receipt = AppStoreUpdateReceipt(plan: plan, state: "accessVerified")
            if submissions == 1 { receipt.failure = self.denied().failure; receipt.state = "failedOrUnconfirmed" }
            submissions += 1
            return try JSONEncoder().encode(receipt)
        })
        let service = AppStoreInstallationService()
        let results = try await service.verifyAccess(plans, batch: batch)
        XCTAssertEqual(starts, 1); XCTAssertEqual(submissions, 2)
        XCTAssertNil(results[0].failure)
        XCTAssertTrue(results[1].failure?.requiresAppManagement == true)
        do {
            _ = try await service.verifyAccess(plans, batch: InstallationAuthorizationBatch(start: { _ in XCTFail("Must reject an installation capability") }))
            XCTFail("An installation session is not an access verification session")
        } catch { }
    }

    func testProbeSessionCancellationDoesNotSubmitRemainingTargetsOrClaimSuccess() async throws {
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.probe", version: "1",
            path: "/Applications/Upovi Probe Fixture.app", teamID: "SYNTHETIC1", isAppStore: true)
        var plan = AppStoreUpdatePlan(application: app, storeID: 12345, version: app.version, userID: 501)
        plan.permissionProbe = true
        let other = InstalledApp(name: "Other", bundleID: "app.synthetic.probe.other", version: "1",
            path: "/Applications/Upovi Other Probe Fixture.app", teamID: "SYNTHETIC1", isAppStore: true)
        var otherPlan = AppStoreUpdatePlan(application: other, storeID: 12346, version: other.version, userID: 501)
        otherPlan.permissionProbe = true
        var submissions = 0
        let batch = InstallationAuthorizationBatch(permissionProbe: true, start: { _ in }, submit: { _ in submissions += 1; throw CancellationError() })
        do {
            _ = try await AppStoreInstallationService().verifyAccess([plan, otherPlan], batch: batch)
            XCTFail("Cancelled probes cannot report success")
        } catch is CancellationError { }
        XCTAssertEqual(submissions, 1)
    }


}
