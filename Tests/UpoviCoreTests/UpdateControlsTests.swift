import XCTest
@testable import UpoviCore

final class UpdateControlsTests: XCTestCase, @unchecked Sendable {
    private let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.controls", version: "1.0", path: "/synthetic/F.app", teamID: "SYNTHETIC")
    private var candidate: UpdateCandidate { .init(version: "2.0", build: "200", source: "Fixture", isCommunity: false, url: nil,
        download: .init(url: URL(string: "https://example.invalid/fixture.zip")!, sha256: String(repeating: "a", count: 64)), releaseNotes: "Notes") }
    func testSkipIsSpecificToVersionBuildChannelAndDeveloper() {
        var policy = UpdatePolicy(); policy.skipped.insert(UpdatePolicy.key(candidate, app: app))
        XCTAssertFalse(policy.allows(candidate, app: app))
        let equivalent = UpdateCandidate(version: "v2.0.0", build: "200", source: "Other source", isCommunity: false, url: nil)
        XCTAssertFalse(policy.allows(equivalent, app: app))
        var next = candidate; next.build = "201"
        XCTAssertTrue(policy.allows(next, app: app))
        next = .init(version: "2.1", source: "Fixture", isCommunity: false, url: nil)
        XCTAssertTrue(policy.allows(next, app: app))
        let other = InstalledApp(name: app.name, bundleID: app.bundleID, version: app.version, path: app.path, teamID: "OTHER")
        XCTAssertTrue(policy.allows(candidate, app: other))
    }
    func testSnoozeExpiresAndRoundTripsWithoutChangingSourceFacts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = UpdatePolicy(); policy.deferredUntil[UpdatePolicy.scope(app)] = now.addingTimeInterval(60)
        let decoded = try JSONDecoder().decode(UpdatePolicy.self, from: JSONEncoder().encode(policy))
        let result = SourceResult(appID: app.id, candidates: [candidate], note: "Checked", status: .updates)
        XCTAssertTrue(decoded.filtering(result, app: app, now: now).candidates.isEmpty)
        XCTAssertEqual(decoded.filtering(result, app: app, now: now.addingTimeInterval(60)).candidates.count, 1)
        XCTAssertEqual(result.candidates.count, 1)
    }
    func testHistoryRecoveryPreservesCommittedAppsAndRequiresReviewForUnfinished() throws {
        let result = SourceResult(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)
        let items = BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: [])
        var record = BulkUpdateRecord(items: items)
        XCTAssertNil(record.entries[0].item.candidate.download)
        XCTAssertNil(record.entries[0].item.candidate.releaseNotes)
        record.update(app.id, phase: .installing, detail: "Installing")
        var restored = try JSONDecoder().decode(BulkUpdateRecord.self, from: JSONEncoder().encode(record))
        restored.recoverInterrupted()
        XCTAssertEqual(restored.entries[0].phase, .interrupted)
        XCTAssertEqual(restored.retryIDs, [app.id])
        restored.update(app.id, phase: .installed, detail: "Done"); restored.recoverInterrupted()
        XCTAssertTrue(restored.retryIDs.isEmpty)
        XCTAssertEqual(restored.entries[0].phase, .installed)
    }
    func testScanLocationsRejectRelativeRootAndDuplicateDefaults() {
        let paths = ScanLocations.normalized(["relative", "/", "/Applications", "/synthetic/../synthetic/Apps", "/synthetic/Apps"])
        XCTAssertEqual(paths, ["/synthetic/Apps"])
        XCTAssertLessThanOrEqual(ScanLocations.normalized((0..<100).map { "/synthetic/\($0)" }).count, 32)
    }
    func testManualHintsNeverInventAComparableVersionOrUseWrongOrcaProduct() {
        XCTAssertNotNil(ManualUpdateSource.forBundle("net.battle.app"))
        XCTAssertNotNil(ManualUpdateSource.forBundle("com.electron.lark"))
        XCTAssertNil(UpdateChecker.casks["com.electron.lark"])
        XCTAssertEqual(UpdateChecker.githubRepositories["com.stablyai.orca"], "stablyai/orca")
        XCTAssertNil(UpdateChecker.casks["com.stablyai.orca"])
        XCTAssertEqual(UpdateChecker.githubRepositories["com.audiout.Audiout"], "aa-hh/Audiout")
    }
    func testVendorManualFlowsDoNotClaimCurrentFromInstallerOrBrowserVersions() async {
        for (bundle, version) in [("net.battle.app", "2.52.8.17651"), ("com.electron.lark", "147.0.7727.149")] {
            let app = InstalledApp(name: "Fixture", bundleID: bundle, version: version, path: "/synthetic/F.app")
            let result = await UpdateChecker.check(app)
            XCTAssertEqual(result.status, .unsupported)
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertNotNil(result.manualURL)
            if bundle == "com.electron.lark" {
                let custom = await UpdateChecker.check(app, override: .init(appcast: URL(string: "http://example.invalid/unused")))
                XCTAssertEqual(custom.status, .unsupported)
                XCTAssertTrue(custom.candidates.isEmpty)
            }
        }
    }
    func testReleaseNotesAreBoundedAndCannotBeProvidedByPeers() throws {
        let long = UpdateCandidate(version: "2.0", source: "Fixture", isCommunity: false, url: nil, releaseNotes: String(repeating: "a", count: 30_000))
        XCTAssertEqual(long.releaseNotes?.count, 20_000)
        let peer = UpdateCandidate(version: "999", source: "Peer", isCommunity: true, url: nil, releaseNotes: "Fake notes")
        XCTAssertNil(peer.releaseNotes)
        XCTAssertEqual(try JSONDecoder().decode(UpdateCandidate.self, from: JSONEncoder().encode(long)).releaseNotes, long.releaseNotes)
    }
    func testAppcastNotesRemainPlainTextWithoutExecutingMarkup() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <description><![CDATA[<h2>New version</h2><p>Fixes and improvements</p>]]></description>
        <enclosure sparkle:shortVersionString="2.0" sparkle:version="200" />
        </item></channel></rss>
        """
        let notes = try AppcastReader.read(Data(xml.utf8)).first?.releaseNotes
        XCTAssertTrue(notes?.contains("New version") == true)
        XCTAssertFalse(notes?.contains("<h2>") == true)
    }
}
