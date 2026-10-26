import XCTest
import UpoviCore
@testable import Upovi

@MainActor
final class UpdateControlsWorkflowTests: XCTestCase {
    private func preferences() throws -> AppPreferences {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-controls-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(url: root.appending(path: "prefs.plist"), migrateUserDefaults: false)
        XCTAssertTrue(prefs.set(false, forKey: GlobalP2PSettings.key)); return prefs
    }
    private let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.controls", version: "1.0", path: "/synthetic/F.app", teamID: "SYNTHETIC")
    private var candidate: UpdateCandidate { .init(version: "2.0", source: "Fixture", isCommunity: false, url: nil,
        download: .init(url: URL(string: "http://example.invalid/fixture.zip")!, sha256: String(repeating: "a", count: 64))) }
    func testSkipControlsCountsBulkPlanningAndNotificationInputAndSurvivesRestart() async throws {
        let prefs = try preferences()
        let value = AppStore(preferences: prefs); value.apps = [app]
        value.sourceResults = [app.id: .init(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)]
        value.setSkipped(candidate, app: app, skipped: true)
        XCTAssertEqual(value.updateCount, 0)
        XCTAssertTrue(value.actionableSourceResults[app.id]?.candidates.isEmpty == true)
        XCTAssertTrue(value.fullAssessment(for: app).hasUpdate)
        value.reviewAllUpdates(); XCTAssertFalse(value.bulkUpdatePresented)
        let restarted = AppStore(preferences: prefs)
        XCTAssertEqual(restarted.updatePolicy.skipped, value.updatePolicy.skipped)
        value.setSkipped(candidate, app: app, skipped: false)
        XCTAssertEqual(value.updateCount, 1)
    }
    func testCompletedFailureBatchIsPersistedAndLoadedForExplicitRetry() async throws {
        let prefs = try preferences(), apps = [app]
        let value = AppStore(preferences: prefs, scanApplications: { _ in apps })
        value.apps = apps; value.sourceResults = [app.id: .init(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)]
        value.reviewAllUpdates(); value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.batchHistory.count, 1)
        XCTAssertNotNil(value.batchHistory[0].finishedAt)
        XCTAssertEqual(value.batchHistory[0].entries[0].phase, .failed)
        let restarted = AppStore(preferences: prefs)
        XCTAssertEqual(restarted.batchHistory[0].retryIDs, [app.id])
        XCTAssertFalse(restarted.bulkUpdating)
        XCTAssertFalse(restarted.bulkUpdatePresented)
    }
    func testCorruptSettingsCannotStartOrCommitABatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-corrupt-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "settings.plist"); try Data("broken".utf8).write(to: file)
        let prefs = AppPreferences(url: file, migrateUserDefaults: false)
        let value = AppStore(preferences: prefs)
        XCTAssertNotNil(prefs.loadFailure)
        value.apps = [app]
        value.sourceResults = [app.id: .init(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)]
        value.reviewAllUpdates(); value.startAllUpdates()
        XCTAssertFalse(value.bulkHasRun)
        XCTAssertFalse(value.bulkUpdating)
        XCTAssertNil(value.bulkTask)
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
    func testRetryRechecksFreshSourcesAndDoesNotRepeatCommittedApplications() async throws {
        let other = InstalledApp(name: "Other", bundleID: "app.synthetic.other", version: "1.0", path: "/synthetic/O.app", teamID: "SYNTHETIC")
        let oldApps = [app, other]
        let oldResults = Dictionary(uniqueKeysWithValues: oldApps.map { ($0.id, SourceResult(appID: $0.id, candidates: [candidate], note: "Old", status: .updates)) })
        var record = BulkUpdateRecord(items: BulkUpdatePlan.make(apps: oldApps, results: oldResults, ignored: []))
        record.update(app.id, phase: .failed, detail: "Failed")
        record.update(other.id, phase: .installed, detail: "Installed")
        record.finishedAt = Date()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in oldApps }, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [.init(version: "3.0", source: "Fresh source", isCommunity: false, url: nil)], note: "Fresh", status: .updates)
        })
        store.retryBatch(record); await store.retryTask?.value
        XCTAssertTrue(store.bulkUpdatePresented)
        XCTAssertEqual(store.bulkItems.map(\.id), [app.id])
        XCTAssertEqual(store.bulkItems.first?.candidate.version, "3.0")
        XCTAssertFalse(store.bulkUpdating)
        XCTAssertNil(store.bulkTask)
    }
    func testRetryDoesNotRepeatATargetCompletedByAnotherUpdater() async throws {
        let old = SourceResult(appID: app.id, candidates: [candidate], note: "Old", status: .updates)
        var record = BulkUpdateRecord(items: BulkUpdatePlan.make(apps: [app], results: [app.id: old], ignored: []))
        record.update(app.id, phase: .failed, detail: "Failed"); record.finishedAt = Date()
        let installed = InstalledApp(name: app.name, bundleID: app.bundleID, version: "2.0", path: app.path, teamID: app.teamID)
        let value = AppStore(preferences: try preferences(), scanApplications: { _ in [installed] }, checkApplication: { app, _ in
            .init(appID: app.id, candidates: [.init(version: "3.0", source: "Fresh", isCommunity: false, url: nil)], note: "Fresh", status: .updates)
        })
        value.retryBatch(record); await value.retryTask?.value
        XCTAssertFalse(value.bulkUpdatePresented)
        XCTAssertFalse(value.bulkUpdating)
        XCTAssertNotNil(value.errorMessage)
    }
}
