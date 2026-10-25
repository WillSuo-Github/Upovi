import XCTest
import UpoviCore
@testable import Upovi

@MainActor
final class ToolbarWorkflowTests: XCTestCase {
    private func app(_ n: Int) -> InstalledApp {
        .init(name: "Fixture \(n)", bundleID: "app.synthetic.toolbar.\(n)", version: "1.0",
              path: "/synthetic/\(n).app", teamID: "SYNTHETIC")
    }
    private func preferences() throws -> AppPreferences {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-toolbar-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let value = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        XCTAssertTrue(value.set(false, forKey: GlobalP2PSettings.key))
        return value
    }
    private func update(for app: InstalledApp) -> SourceResult {
        .init(appID: app.id, candidates: [.init(version: "2.0", source: "Fixture source", isCommunity: false,
            url: URL(string: "https://example.invalid/"), download: .init(url: URL(string: "https://example.invalid/update.zip")!,
            sha256: String(repeating: "a", count: 64)))], note: "Fixture", status: .updates)
    }

    func testRefreshScansThenChecksEntireNewInventoryDespiteFiltersAndBackgroundSync() async throws {
        let fresh = (0..<7).map { app($0) }, tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: {
            await tracker.record("scan"); return fresh
        }, checkApplication: { app, _ in
            await tracker.record(app.id)
            return .init(appID: app.id, candidates: [.init(version: "2.0", source: "Fixture source", isCommunity: false, url: nil)], note: "Fixture", status: .updates)
        })
        store.apps = [app(999)]; store.search = "no-visible-apps"; store.sourceFilter = .unsupported
        store.syncing = true
        store.refreshAll()
        await store.checkTask?.value
        let events = await tracker.events
        XCTAssertEqual(events.first, "scan")
        XCTAssertEqual(Set(events.dropFirst()), Set(fresh.map(\.id)))
        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(store.apps, fresh)
        XCTAssertEqual(store.sourceResults.count, 7)
        XCTAssertEqual(store.completedChecks, 7)
        XCTAssertNotNil(store.lastChecked)
        XCTAssertFalse(store.refreshing)
        XCTAssertFalse(store.checking)
        XCTAssertTrue(store.visibleApps.isEmpty)
    }

    func testCancellationDuringScanPreventsSubsequentSourceChecks() async throws {
        let fresh = [app(1)], gate = ScanGate(), tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: {
            await gate.pause(); return fresh
        }, checkApplication: { app, _ in
            await tracker.record(app.id)
            return .init(appID: app.id, candidates: [], note: "Fixture", status: .current)
        })
        store.refreshAll()
        await gate.waitUntilPaused()
        store.cancelChecking()
        await gate.resume()
        await store.checkTask?.value
        let events = await tracker.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(store.refreshing)
        XCTAssertFalse(store.scanning)
        XCTAssertNil(store.lastChecked)
    }

    func testBulkActionUsesAllUpdatesAndLocksOtherOperationsWhileReviewing() async throws {
        let store = AppStore(preferences: try preferences())
        store.apps = (0..<4).map { app($0) }
        store.sourceResults = Dictionary(uniqueKeysWithValues: store.apps.map { ($0.id, update(for: $0)) })
        store.ignored = [store.apps[3].bundleID]
        store.search = "no-visible-apps"; store.sourceFilter = .unsupported
        store.reviewAllUpdates()
        XCTAssertTrue(store.bulkUpdatePresented)
        XCTAssertEqual(store.bulkInstallableCount, 3)
        XCTAssertTrue(store.visibleApps.isEmpty)
        XCTAssertTrue(store.installationBusy)
        store.refreshAll(); store.beginChecking()
        XCTAssertNil(store.checkTask)
        XCTAssertFalse(store.refreshing)
        XCTAssertFalse(store.checking)
        let first = store.bulkItems[0]
        store.prepareInstallation(first.candidate, app: first.application)
        XCTAssertNil(store.installationTask)
        store.bulkUpdatePresented = false
        XCTAssertFalse(store.installationBusy)
    }

    func testOfflineBulkStartDoesNotLaunchInstallation() async throws {
        let store = AppStore(preferences: try preferences())
        let a = app(1); store.apps = [a]; store.sourceResults = [a.id: update(for: a)]
        store.reviewAllUpdates(); store.networkAvailable = false; store.startAllUpdates()
        XCTAssertFalse(store.bulkUpdating)
        XCTAssertFalse(store.bulkHasRun)
        XCTAssertNil(store.bulkTask)
        XCTAssertNotNil(store.errorMessage)
    }

    func testRealBulkPreparationFailuresFinishQueueAndReleaseBusyState() async throws {
        let apps = [app(1), app(2)]
        let journal = FileManager.default.temporaryDirectory.appending(path: "Upovi-toolbar-journal-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: journal) }
        let store = AppStore(preferences: try preferences(), installer: UpdateInstaller(journalDirectory: journal), scanApplications: { apps })
        store.apps = apps
        // The production downloader rejects HTTP before any request or application mutation.
        store.sourceResults = Dictionary(uniqueKeysWithValues: apps.map { app in
            (app.id, .init(appID: app.id, candidates: [.init(version: "2.0", source: "Fixture", isCommunity: false,
                url: nil, download: .init(url: URL(string: "http://example.invalid/update.zip")!, sha256: String(repeating: "a", count: 64)))], note: "Fixture", status: SourceStatus.updates))
        })
        store.reviewAllUpdates(); store.startAllUpdates()
        await store.bulkTask?.value
        XCTAssertEqual(store.bulkFailedCount, 2)
        XCTAssertEqual(store.bulkCompletedCount, 0)
        XCTAssertEqual(store.bulkOutcomes.count, 2)
        XCTAssertEqual(store.updateCount, 2)
        XCTAssertFalse(store.bulkUpdating)
        XCTAssertFalse(store.installing)
        XCTAssertFalse(store.installationBusy)
        XCTAssertFalse(store.canCancelInstallation)
        XCTAssertNil(store.preparedUpdate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
}

private actor RefreshTracker {
    var events: [String] = []
    func record(_ value: String) { events.append(value) }
}

private actor ScanGate {
    private var scanner: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation {
            scanner = $0; observer?.resume(); observer = nil
        }
    }
    func waitUntilPaused() async {
        if scanner != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { scanner?.resume(); scanner = nil }
}
