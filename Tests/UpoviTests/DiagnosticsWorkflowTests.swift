import XCTest
import UpoviCore
@testable import Upovi

@MainActor
final class DiagnosticsWorkflowTests: XCTestCase {
    private func preferences() throws -> AppPreferences {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-diagnostics-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(url: root.appending(path: "prefs.plist"), migrateUserDefaults: false)
        XCTAssertTrue(prefs.set(false, forKey: GlobalP2PSettings.key)); return prefs
    }
    func testFailedSinglePreparationIsClassifiedPersistedAndExportedWithoutDetails() async throws {
        let prefs = try preferences(), store = AppStore(preferences: prefs)
        let app = InstalledApp(name: "Private name", bundleID: "dev.private.fixture", version: "1", path: "/private/Secret.app")
        store.apps = [app]
        store.prepareInstallation(.init(version: "2", source: "Private source", isCommunity: false, url: nil), app: app)
        await store.installationTask?.value
        XCTAssertEqual(store.diagnosticEvents.first?.stage, .preparation)
        let restarted = AppStore(preferences: prefs); restarted.apps = [app]
        XCTAssertEqual(restarted.diagnosticEvents.count, 1)
        let data = try restarted.diagnosticSnapshot().report()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("preparation")); XCTAssertTrue(text.contains("validationRejected"))
        XCTAssertFalse(text.contains(app.path)); XCTAssertFalse(text.contains(app.bundleID)); XCTAssertFalse(text.contains(app.name))
    }
    func testDiagnosticHistoryIsBoundedAndPreviewSnapshotDoesNotFollowLaterMutations() throws {
        let store = AppStore(preferences: try preferences())
        for _ in 0..<60 { store.recordDiagnostic(.backupCleanup, error: URLError(.timedOut)) }
        XCTAssertEqual(store.diagnosticEvents.count, 50)
        let snapshot = store.diagnosticSnapshot(), before = try snapshot.report()
        store.apps = [.init(name: "Later", bundleID: "dev.later", version: "1", path: "/later.app")]
        store.networkAvailable = false
        XCTAssertEqual(try snapshot.report(), before)
        XCTAssertNotEqual(try store.diagnosticSnapshot().report(), before)
    }
    func testNetworkLossBetweenBatchStartAndPreparationIsRecorded() async throws {
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.offline", version: "1", path: "/synthetic/Offline.app", teamID: "SYNTHETIC")
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in [app] })
        store.apps = [app]
        let candidate = UpdateCandidate(version: "2", source: "Fixture", isCommunity: false, url: nil,
            download: .init(url: URL(string: "https://example.invalid/App.zip")!, sha256: String(repeating: "a", count: 64)))
        store.sourceResults = [app.id: .init(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)]
        store.reviewAllUpdates(); XCTAssertEqual(store.bulkInstallableCount, 1)
        store.startAllUpdates(); XCTAssertNotNil(store.bulkTask); store.networkAvailable = false
        await store.bulkTask?.value
        XCTAssertEqual(store.diagnosticEvents.first?.stage, .batchPreparation)
        XCTAssertEqual(store.diagnosticEvents.first?.issue.kind, .offline)
        XCTAssertEqual(store.batchHistory.first?.entries.first?.phase, .failed)
    }

}
