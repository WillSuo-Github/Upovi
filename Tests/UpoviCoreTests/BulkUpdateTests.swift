import XCTest
@testable import UpoviCore

final class BulkUpdateTests: XCTestCase, @unchecked Sendable {
    private func app(_ n: Int, team: String? = "SYNTHETIC", bundle: String? = nil, store: Bool = false) -> InstalledApp {
        .init(name: "Fixture \(n)", bundleID: bundle ?? "app.synthetic.\(n)", version: "1.0", build: "100",
              path: "/synthetic/\(n).app", teamID: team, isAppStore: store)
    }
    private func candidate(_ version: String = "2.0", build: String = "200", proof: Bool = true, ext: String = "zip", peer: Bool = false) -> UpdateCandidate {
        .init(version: version, build: build, source: "Synthetic source", isCommunity: peer,
              url: URL(string: "https://example.invalid/releases"), download: .init(url: URL(string: "https://example.invalid/update.\(ext)")!,
              sha256: proof ? String(repeating: "a", count: 64) : nil))
    }
    private func results(_ apps: [InstalledApp], candidates: [UpdateCandidate]? = nil) -> [String: SourceResult] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.id, .init(appID: $0.id, candidates: candidates ?? [candidate()], note: "Fixture", status: .updates)) })
    }
    private func plan(_ count: Int = 3) -> [BulkUpdateItem] {
        let apps = (0..<count).map { app($0) }
        return BulkUpdatePlan.make(apps: apps, results: results(apps), ignored: [])
    }

    func testFullInventoryDoesNotLimitBatchAndIgnoredAppsStayOut() {
        let apps = (0..<73).map { app($0) }
        let items = BulkUpdatePlan.make(apps: apps + [apps[0]], results: results(apps), ignored: [apps[17].bundleID])
        XCTAssertEqual(items.count, 72)
        XCTAssertEqual(Set(items.map(\.id)), Set(apps.filter { $0 != apps[17] }.map(\.id)))
        XCTAssertTrue(items.allSatisfy(\.canInstall))
    }

    func testPeerClaimsFailedChecksWrongIdentityAndCurrentVersionsCannotEnterQueue() {
        let a = app(1)
        for r in [SourceResult(appID: a.id, candidates: [candidate(peer: true)], note: "Peer", status: .updates),
                  .init(appID: a.id, candidates: [candidate()], note: "Failed", status: .failed),
                  .init(appID: "/wrong.app", candidates: [candidate()], note: "Wrong", status: .updates),
                  .init(appID: a.id, candidates: [candidate("1.0", build: "100")], note: "Current", status: .updates)] {
            XCTAssertTrue(BulkUpdatePlan.make(apps: [a], results: [a.id: r], ignored: []).isEmpty)
        }
    }

    func testManualNewestReleaseDoesNotFallBackToOlderDownload() {
        let a = app(1)
        let items = BulkUpdatePlan.make(apps: [a], results: results([a], candidates: [candidate("3.0", proof: false), candidate("2.0")]), ignored: [])
        XCTAssertEqual(items.first?.candidate.version, "3.0")
        XCTAssertFalse(items.first?.canInstall ?? true)
    }

    func testHighestBuildAndEquivalentDownloadSourceAreSelected() {
        let a = app(1)
        let items = BulkUpdatePlan.make(apps: [a], results: results([a], candidates: [candidate(build: "200"), candidate(build: "201", proof: false), candidate(build: "201")]), ignored: [])
        XCTAssertEqual(items.first?.candidate.build, "201")
        XCTAssertTrue(items.first?.canInstall ?? false)
    }
    func testEquivalentMarketingVersionDoesNotHideAVerifiableDownload() {
        let a = app(1)
        let items = BulkUpdatePlan.make(apps: [a], results: results([a], candidates: [candidate("v2.0", proof: false), candidate("2.0.0")]), ignored: [])
        XCTAssertTrue(items[0].canInstall)
        XCTAssertNotNil(items[0].candidate.download)
    }

    func testManualChannelsMissingIdentityIntegrityAndUnsupportedFormatsAreReported() {
        let apps = [app(0, store: true), app(1, bundle: "app.upovi.Upovi"), app(2, team: nil), app(3)]
        let items = BulkUpdatePlan.make(apps: apps, results: results(apps), ignored: [])
        XCTAssertEqual(items.map(\.canInstall), [false, false, false, true])
        XCTAssertFalse(BulkUpdatePlan.make(apps: [apps[3]], results: results([apps[3]], candidates: [candidate(ext: "exe")]), ignored: [])[0].canInstall)
        XCTAssertFalse(BulkUpdatePlan.make(apps: [apps[3]], results: results([apps[3]], candidates: [candidate(proof: false)]), ignored: [])[0].canInstall)
        XCTAssertTrue(BulkUpdatePlan.make(apps: [apps[3]], results: results([apps[3]], candidates: [candidate(ext: "pkg")]), ignored: [])[0].canInstall)
    }

    func testFailureContinuesSequentiallyWithoutClaimingSuccess() async {
        let items = plan(), tracker = Tracker()
        let outcomes = await BulkUpdateRunner.run(items, shouldStop: { false }, operation: { item in
            await tracker.append(item.id)
            if item.id == items[1].id { throw PeerError.invalid("Synthetic verification failure") }
        }, report: { _ in })
        let calls = await tracker.calls
        XCTAssertEqual(calls, items.map(\.id))
        XCTAssertEqual(outcomes.map(\.status), [.installed, .failed, .installed])
        XCTAssertTrue(outcomes[1].detail.contains("Synthetic verification failure"))
    }

    func testStopAfterCommitKeepsSuccessAndDoesNotStartRemainingApps() async {
        let items = plan(), tracker = Tracker()
        let outcomes = await BulkUpdateRunner.run(items, shouldStop: { await tracker.stop }, operation: { item in
            await tracker.append(item.id); await tracker.requestStop()
        }, report: { _ in })
        let calls = await tracker.calls
        XCTAssertEqual(calls, [items[0].id])
        XCTAssertEqual(outcomes.map(\.status), [.installed, .cancelled, .cancelled])
    }

    func testDownloadCancellationStopsRunningAndRemainingApps() async {
        let items = plan(), tracker = Tracker()
        let task = Task {
            await BulkUpdateRunner.run(items, shouldStop: { false }, operation: { item in
                await tracker.append(item.id)
                try await Task.sleep(for: .seconds(30))
            }, report: { _ in })
        }
        await tracker.waitForStart()
        task.cancel()
        let outcomes = await task.value, calls = await tracker.calls
        XCTAssertEqual(calls, [items[0].id])
        XCTAssertEqual(outcomes.map(\.status), [.cancelled, .cancelled, .cancelled])
    }

    func testManualItemsNeverInvokeInstaller() async {
        let a = app(1, store: true), tracker = Tracker()
        let items = BulkUpdatePlan.make(apps: [a], results: results([a]), ignored: [])
        let outcomes = await BulkUpdateRunner.run(items, shouldStop: { false }, operation: { await tracker.append($0.id) }, report: { _ in })
        let calls = await tracker.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(outcomes.map(\.status), [.manual])
    }

    func testConcurrentRunHonorsLimitAndKeepsOutcomeOrder() async {
        let items = plan(12), meter = ConcurrencyMeter()
        let outcomes = await BulkUpdateRunner.run(items, concurrency: 5, shouldStop: { false }, operation: { item in
            await meter.enter()
            try await Task.sleep(for: .milliseconds(20))
            await meter.leave()
            if item.id == items[3].id { throw PeerError.invalid("Synthetic failure") }
        }, report: { _ in })
        let peak = await meter.peak
        XCTAssertEqual(peak, 5)
        XCTAssertEqual(outcomes.map(\.item.id), items.map(\.id))
        XCTAssertEqual(outcomes.filter { $0.status == .failed }.map(\.item.id), [items[3].id])
        XCTAssertEqual(outcomes.filter { $0.status == .installed }.count, 11)
    }

    func testConcurrentStopLetsRunningItemsFinishAndSkipsQueuedItems() async {
        let items = plan(8), tracker = Tracker()
        let outcomes = await BulkUpdateRunner.run(items, concurrency: 3, shouldStop: { await tracker.stop }, operation: { item in
            await tracker.append(item.id)
            // Request stop only once all three slots are occupied, so the expectation is deterministic.
            if item.id == items[0].id {
                while await tracker.calls.count < 3 { try await Task.sleep(for: .milliseconds(1)) }
                await tracker.requestStop()
            } else {
                while await !tracker.stop { try await Task.sleep(for: .milliseconds(1)) }
            }
        }, report: { _ in })
        let calls = await tracker.calls
        XCTAssertEqual(Set(calls), Set(items.prefix(3).map(\.id)))
        XCTAssertEqual(outcomes.prefix(3).map(\.status), [.installed, .installed, .installed])
        XCTAssertTrue(outcomes.dropFirst(3).allSatisfy { $0.status == .cancelled })
    }

    func testSerialGateNeverOverlaps() async throws {
        let gate = SerialGate(), meter = ConcurrencyMeter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gate.run {
                        await meter.enter(); try await Task.sleep(for: .milliseconds(5)); await meter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await meter.peak
        XCTAssertEqual(peak, 1)
    }
    func testUnityHubEditorsAreLeftToTheOfficialChannel() {
        let editor = InstalledApp(name: "Unity", bundleID: "com.unity3d.UnityEditor5.x", version: "6000.6.0f1", build: "6000.6.0f1",
                                  path: "/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app", teamID: "BVPN9UFA9B")
        let items = BulkUpdatePlan.make(apps: [editor], results: results([editor], candidates: [candidate("6000.6.7f1", build: "", ext: "pkg")]), ignored: [])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].canInstall)
    }
}

private actor ConcurrencyMeter {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private actor Tracker {
    var calls: [String] = []
    var stop = false
    private var waiter: CheckedContinuation<Void, Never>?
    func append(_ id: String) { calls.append(id); waiter?.resume(); waiter = nil }
    func requestStop() { stop = true }
    func waitForStart() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
