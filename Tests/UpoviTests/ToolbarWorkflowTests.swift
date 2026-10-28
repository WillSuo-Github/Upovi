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

    func testFreshStartupChecksSourcesWithPeriodicChecksDisabledAndDoesNotRepeatOnReappearance() async throws {
        let fresh = [app(1), app(2)], tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in
            await tracker.record("scan"); return fresh
        }, revalidateSources: { await tracker.record("revalidate") }, checkApplication: { app, _ in
            await tracker.record(app.id)
            return .init(appID: app.id, candidates: [], note: "Fixture", status: .current)
        })
        XCTAssertFalse(store.automaticChecks)
        store.startInitialCheck()
        await store.checkTask?.value
        let first = await tracker.events
        XCTAssertEqual(Array(first.prefix(2)), ["scan", "revalidate"])
        XCTAssertEqual(Set(first.dropFirst(2)), Set(fresh.map(\.id)))
        XCTAssertEqual(store.completedChecks, fresh.count)
        XCTAssertNotNil(store.lastChecked)
        XCTAssertFalse(store.operationBusy)
        store.startInitialCheck()
        let repeated = await tracker.events
        XCTAssertEqual(first, repeated)
        XCTAssertFalse(store.automaticChecks)
    }

    func testStartupReentryWhileScanningDoesNotCreateAnotherScanOrCheck() async throws {
        let fresh = [app(1)], gate = ScanGate(), tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in
            await tracker.record("scan"); await gate.pause(); return fresh
        }, revalidateSources: { }, checkApplication: { app, _ in
            await tracker.record("check")
            return .init(appID: app.id, candidates: [], note: "Fixture", status: .current)
        })
        store.startInitialCheck()
        await gate.waitUntilPaused()
        store.startInitialCheck()
        await gate.resume()
        await store.checkTask?.value
        let events = await tracker.events
        XCTAssertEqual(events, ["scan", "check"])
        XCTAssertEqual(store.checkHistory.count, 1)
    }

    func testCancelledStartupDoesNotRestartWhenTheViewReappears() async throws {
        let fresh = [app(1)], gate = ScanGate(), tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in
            await gate.pause(); return fresh
        }, revalidateSources: { await tracker.record("revalidate") }, checkApplication: { app, _ in
            await tracker.record("check")
            return .init(appID: app.id, candidates: [], note: "Fixture", status: .current)
        })
        store.startInitialCheck()
        await gate.waitUntilPaused()
        store.cancelChecking()
        await gate.resume()
        await store.checkTask?.value
        store.startInitialCheck()
        let events = await tracker.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(store.lastChecked)
        XCTAssertFalse(store.operationBusy)
    }

    func testOfflineStartupScansAndExplainsWhySourceChecksDidNotRun() async throws {
        let fresh = [app(1)], tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in fresh },
                             revalidateSources: { await tracker.record("revalidate") }, checkApplication: { app, _ in
            await tracker.record("check")
            return .init(appID: app.id, candidates: [], note: "Fixture", status: .current)
        })
        store.networkAvailable = false
        store.startInitialCheck()
        await store.checkTask?.value
        let events = await tracker.events
        XCTAssertEqual(store.apps, fresh)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(store.errorMessage, String(localized: "应用已重新扫描；当前没有可用网络，联网后再检查更新。"))
        XCTAssertNil(store.lastChecked)
        XCTAssertFalse(store.operationBusy)
    }

    func testStartupDoesNotReplaceAnAlreadyPopulatedStore() async throws {
        let tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in
            await tracker.record("scan"); return []
        })
        store.apps = [app(1)]
        store.sourceResults = [store.apps[0].id: update(for: store.apps[0])]
        store.startInitialCheck()
        let events = await tracker.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(store.checkTask)
        XCTAssertEqual(store.sourceResults.count, 1)
    }

    func testRefreshScansThenChecksEntireNewInventoryDespiteFiltersAndBackgroundSync() async throws {
        let fresh = (0..<7).map { app($0) }, tracker = RefreshTracker()
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in
            await tracker.record("scan"); return fresh
        }, revalidateSources: { await tracker.record("revalidate") }, checkApplication: { app, _ in
            await tracker.record(app.id)
            return .init(appID: app.id, candidates: [.init(version: "2.0", source: "Fixture source", isCommunity: false, url: nil)], note: "Fixture", status: .updates)
        })
        store.apps = [app(999)]; store.search = "no-visible-apps"; store.sourceFilter = .unsupported
        store.syncing = true
        store.refreshAll()
        await store.checkTask?.value
        let events = await tracker.events
        XCTAssertEqual(events.first, "scan")
        XCTAssertEqual(events.dropFirst().first, "revalidate")
        XCTAssertEqual(Set(events.dropFirst(2)), Set(fresh.map(\.id)))
        XCTAssertEqual(events.count, 9)
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
        let store = AppStore(preferences: try preferences(), scanApplications: { _ in
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
        let store = AppStore(preferences: try preferences(), installer: UpdateInstaller(journalDirectory: journal), scanApplications: { _ in apps })
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
