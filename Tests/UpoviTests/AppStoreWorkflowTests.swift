import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class AppStoreWorkflowTests: XCTestCase {
    func testStoreUpdateUsesSharedReviewHistoryAndInstallerWithoutDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path:"Upovi-store-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let preferences = AppPreferences(url:root.appending(path:"settings.plist"),migrateUserDefaults:false)
        preferences.set(false,forKey:GlobalP2PSettings.key)
        let app = InstalledApp(name:"Store fixture",bundleID:"app.synthetic.store",version:"1",path:"/Applications/Upovi Synthetic Store.app",teamID:"SYNTHETIC1",isAppStore:true)
        let store = AppStore(preferences:preferences,scanApplications:{_ in [app]})
        store.apps = [app]
        let candidate = UpdateCandidate(version:"2",source:"App Store",isCommunity:false,url:nil,appStoreID:12345)
        var invoked = false
        store.installStoreUpdate = { value,target,_ in invoked = true; XCTAssertEqual(value.appStoreID,12345); XCTAssertEqual(target,app); XCTAssertFalse(store.canCancelInstallation) }
        store.reviewStoreUpdate(app,candidate:candidate)
        XCTAssertTrue(store.bulkUpdatePresented); XCTAssertEqual(store.bulkInstallableCount,1)
        store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertTrue(invoked); XCTAssertEqual(store.bulkCompletedCount,1); XCTAssertFalse(store.installationBusy)
        XCTAssertEqual(store.batchHistory.first?.entries.first?.phase,.installed)
        XCTAssertEqual(store.batchHistory.first?.entries.first?.detail, String(localized: "商店更新完成，不提供 Upovi 旧版备份"))
        XCTAssertTrue(SourceFilter.appStore.includes(.updates,isAppStore:true))
        XCTAssertFalse(SourceFilter.appStore.includes(.updates,isAppStore:false))
    }
    func testCurrentResultPreservesCheckedStateAndDoesNotRecordAnInstallOrDiagnosticFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path:"Upovi-store-current-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let preferences = AppPreferences(url:root.appending(path:"settings.plist"),migrateUserDefaults:false)
        preferences.set(false,forKey:GlobalP2PSettings.key)
        let app = InstalledApp(name:"Store fixture",bundleID:"app.synthetic.store",version:"1",path:"/Applications/Upovi Synthetic Store.app",teamID:"SYNTHETIC1",isAppStore:true)
        let store = AppStore(preferences:preferences,scanApplications:{_ in [app]}); store.apps = [app]
        store.installStoreUpdate = { _,_,_ in throw AppStoreAlreadyCurrent() }
        store.reviewStoreUpdate(app,candidate:.init(version:"1",source:"App Store",isCommunity:false,url:nil,appStoreID:12345))
        store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(store.sourceResults[app.id]?.status,.current)
        XCTAssertEqual(store.sourceResults[app.id]?.appStoreID,12345)
        XCTAssertEqual(store.batchHistory.first?.entries.first?.phase,.current)
        XCTAssertTrue(store.batchHistory.first?.retryIDs.isEmpty == true)
        XCTAssertTrue(store.diagnosticEvents.isEmpty)
    }

}

extension AppStoreWorkflowTests {
    private func batchFixture() throws -> (AppStore, [InstalledApp]) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-batch-workflow-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        let apps = (1...3).map { index in
            InstalledApp(name: "Store \(index)", bundleID: "app.synthetic.store\(index)", version: "1",
                path: "/Applications/Upovi Synthetic Store \(index).app", teamID: "SYNTHETIC1", isAppStore: true)
        }
        let store = AppStore(preferences: preferences, scanApplications: { _ in apps })
        store.apps = apps
        store.sourceResults = Dictionary(uniqueKeysWithValues: apps.map { app in
            (app.id, SourceResult(appID: app.id, candidates: [.init(version: "2", source: "App Store", isCommunity: false, url: nil, appStoreID: 12345)], note: "", status: .updates))
        })
        return (store, apps)
    }

    func testBulkWaitsForEveryPreflightAndRunsOneAuthorizationDespiteAnInstallerFailure() async throws {
        let (store, apps) = try batchFixture()
        var preflights = 0, authorizations = 0
        store.makeInstallationAuthorizationBatch = {
            InstallationAuthorizationBatch { command, count in
                authorizations += 1
                XCTAssertEqual(preflights, 3)
                XCTAssertEqual(count, 3)
                XCTAssertEqual(store.bulkCompletedCount, 0)
                return try await ProcessCommand().run("/bin/sh", ["-c", command])
            }
        }
        store.installStoreUpdate = { _, app, authorization in
            if app.id == apps[0].id { try await Task.sleep(for: .milliseconds(40)) }
            preflights += 1
            _ = try await authorization.run(app.id == apps[1].id ? "exit 23" : "printf 'installed'", nil)
        }
        store.reviewAllUpdates(); store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(store.bulkCompletedCount, 2)
        XCTAssertEqual(store.bulkFailedCount, 1)
        XCTAssertEqual(store.bulkOutcomes[apps[1].id]?.status, .failed)
        XCTAssertNotNil(store.batchHistory.first?.finishedAt)
    }

    func testFailedPreflightCannotDeadlockOtherInstallersOrCreateAnotherPrompt() async throws {
        let (store, apps) = try batchFixture()
        var authorizations = 0
        store.makeInstallationAuthorizationBatch = {
            InstallationAuthorizationBatch { command, count in
                authorizations += 1; XCTAssertEqual(count, 2)
                return try await ProcessCommand().run("/bin/sh", ["-c", command])
            }
        }
        store.installStoreUpdate = { _, app, authorization in
            if app.id == apps[0].id { throw PeerError.unavailable("Synthetic preflight failure") }
            _ = try await authorization.run("printf 'installed'", nil)
        }
        store.reviewAllUpdates(); store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(store.bulkCompletedCount, 2)
        XCTAssertEqual(store.bulkFailedCount, 1)
    }

    func testStoppingBeforeAuthorizationDoesNotLaunchAnyPrivilegedCommand() async throws {
        let (store, _) = try batchFixture()
        var authorizations = 0
        store.makeInstallationAuthorizationBatch = {
            InstallationAuthorizationBatch { _, _ in authorizations += 1; return Data() }
        }
        store.installStoreUpdate = { _, _, authorization in
            store.stopAllUpdates()
            _ = try await authorization.run("exit 99", nil)
        }
        store.reviewAllUpdates(); store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(authorizations, 0)
        XCTAssertEqual(store.bulkOutcomes.values.filter { $0.status == .cancelled }.count, 3)
        XCTAssertFalse(store.bulkUpdating)
    }
}
