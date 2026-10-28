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
        store.installStoreUpdate = { value,target in invoked = true; XCTAssertEqual(value.appStoreID,12345); XCTAssertEqual(target,app); XCTAssertFalse(store.canCancelInstallation) }
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
        store.installStoreUpdate = { _,_ in throw AppStoreAlreadyCurrent() }
        store.reviewStoreUpdate(app,candidate:.init(version:"1",source:"App Store",isCommunity:false,url:nil,appStoreID:12345))
        store.startAllUpdates(); await store.bulkTask?.value
        XCTAssertEqual(store.sourceResults[app.id]?.status,.current)
        XCTAssertEqual(store.sourceResults[app.id]?.appStoreID,12345)
        XCTAssertEqual(store.batchHistory.first?.entries.first?.phase,.current)
        XCTAssertTrue(store.batchHistory.first?.retryIDs.isEmpty == true)
        XCTAssertTrue(store.diagnosticEvents.isEmpty)
    }

}
