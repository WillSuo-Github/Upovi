import XCTest
@testable import UpoviCore

final class UpdateAssessmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var app: InstalledApp {
        .init(name: "Fixture", bundleID: "app.synthetic.trust", version: "1.0", build: "100", path: "/synthetic/Fixture.app")
    }
    private func peer(_ version: String = "999.0", build: String = "", id: String? = "publisher-a", expired: Bool = false) -> UpdateCandidate {
        .init(version: version, build: build, source: "Public peer", isCommunity: true, url: nil,
            observedAt: now.addingTimeInterval(-60), peerID: id, expiresAt: now.addingTimeInterval(expired ? -1 : 3600))
    }
    private func source(_ version: String = "2.0", build: String = "", usesBuildVersion: Bool = false) -> UpdateCandidate {
        .init(version: version, build: build, source: "Developer appcast", isCommunity: false,
            url: URL(string: "https://example.invalid/releases"), usesBuildVersion: usesBuildVersion)
    }
    private func result(_ candidates: [UpdateCandidate], status: SourceStatus = .updates) -> SourceResult {
        .init(appID: app.id, candidates: candidates, note: "Synthetic fixture", status: status)
    }

    func testForgedHighVersionNeverBecomesUpdateOrNotificationEvenIfPlacedInSourceResult() {
        let forged = peer()
        let assessment = UpdateAssessment(app: app, sourceResult: result([forged]), reports: [forged], now: now)
        XCTAssertFalse(assessment.hasUpdate)
        XCTAssertEqual(assessment.communityLeads.count, 1)
        XCTAssertEqual(assessment.communityLeads.first?.confirmation, .unverified)
        XCTAssertTrue(UpdateAssessment.notificationBatch(apps: [app], results: [app.id: result([forged])], ignored: [], seen: []).isEmpty)
    }

    func testCryptographicallyValidFalseClaimStillHasNoUpdateAuthority() throws {
        let publisher = PeerIdentity()
        let claimedApp = InstalledApp(name: app.name, bundleID: app.bundleID, version: "999.0", path: "/not-a-real-install")
        let signed = try publisher.signPublic(VersionReport(app: claimedApp), sequence: 1)
        let decoded = try CommunityTopic.decode(signed, for: app)
        XCTAssertTrue(signed.isValid)
        let candidate = UpdateCandidate(version: decoded.version, build: decoded.build, source: "Signed peer", isCommunity: true,
            url: nil, observedAt: decoded.observedAt, peerID: publisher.invitation.shortID, expiresAt: decoded.expiresAt)
        let assessment = UpdateAssessment(app: app, sourceResult: nil, reports: [candidate])
        XCTAssertEqual(assessment.communityLeads.first?.report.version, "999.0")
        XCTAssertEqual(assessment.communityLeads.first?.confirmation, .unverified)
        XCTAssertFalse(assessment.hasUpdate)
        XCTAssertTrue(UpdateAssessment.notificationBatch(apps: [app], results: [app.id: result([candidate])], ignored: [], seen: []).isEmpty)
    }

    func testManyPublisherIdentitiesDoNotEstablishAuthority() {
        let reports = (0..<100).map { peer(id: "key-\($0)") }
        let assessment = UpdateAssessment(app: app, sourceResult: nil, reports: reports, now: now)
        XCTAssertFalse(assessment.hasUpdate)
        XCTAssertEqual(assessment.communityLeads.count, 1)
        XCTAssertEqual(assessment.communityLeads.first?.publisherCount, 100)
        XCTAssertEqual(assessment.communityLeads.first?.confirmation, .multiplePublishers)
        XCTAssertTrue(assessment.communityLeads.first?.matchingSources.isEmpty == true)
    }

    func testSourceConfirmsOnlyMatchingVersionAndDoesNotCountReportsTwice() {
        let sources = result([source(), .init(version: "2.0", source: "GitHub Release", isCommunity: false, url: nil)])
        let assessment = UpdateAssessment(app: app, sourceResult: sources,
            reports: [peer(), peer("v2.0.0", id: "publisher-b")], now: now)
        XCTAssertTrue(assessment.hasUpdate)
        XCTAssertEqual(assessment.communityLeads.first { $0.report.version == "999.0" }?.confirmation, .unverified)
        let matched = assessment.communityLeads.first { $0.report.version == "v2.0.0" }
        XCTAssertEqual(matched?.confirmation, .sourceMatched)
        XCTAssertEqual(matched?.matchingSources, ["Developer appcast", "GitHub Release"])
        let batch = UpdateAssessment.notificationBatch(apps: [app], results: [app.id: sources], ignored: [], seen: [])
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.deduplicationKeys, ["app.synthetic.trust:2.0:"])
    }

    func testBuildMustBeConfirmedWhenPeerClaimsOne() {
        let reports = [peer("2.0", build: "999"), peer("2.0", build: "200", id: "b"), peer("2.0", id: "c")]
        let assessment = UpdateAssessment(app: app, sourceResult: result([source(build: "200")]), reports: reports, now: now)
        XCTAssertEqual(assessment.communityLeads.first { $0.report.build == "999" }?.confirmation, .unverified)
        XCTAssertEqual(assessment.communityLeads.first { $0.report.build == "200" }?.confirmation, .sourceMatched)
        XCTAssertEqual(assessment.communityLeads.first { $0.report.build.isEmpty }?.confirmation, .sourceMatched)
        let missingBuild = UpdateAssessment(app: app, sourceResult: result([source()]), reports: [reports[0]], now: now)
        XCTAssertEqual(missingBuild.communityLeads.first?.confirmation, .unverified)
    }

    func testBuildOnlyAppcastCannotConfirmPeerMarketingVersion() {
        let assessment = UpdateAssessment(app: app, sourceResult: result([source("200", build: "200", usesBuildVersion: true)]),
            reports: [peer("200", build: "200")], now: now)
        XCTAssertTrue(assessment.hasUpdate)
        XCTAssertEqual(assessment.communityLeads.first?.confirmation, .unverified)
    }

    func testDuplicateUnknownAndExpiredPublishersDoNotInflateCorroboration() {
        let assessment = UpdateAssessment(app: app, sourceResult: nil,
            reports: [peer(), peer(), peer(id: nil), peer(id: ""), peer(id: "expired", expired: true)], now: now)
        XCTAssertEqual(assessment.communityLeads.count, 1)
        XCTAssertEqual(assessment.communityLeads.first?.publisherCount, 1)
        XCTAssertEqual(assessment.communityLeads.first?.confirmation, .unverified)
        XCTAssertTrue(UpdateAssessment(app: app, sourceResult: nil, reports: [peer(expired: true)], now: now).communityLeads.isEmpty)
        var future = peer(); future.observedAt = now.addingTimeInterval(301)
        XCTAssertTrue(UpdateAssessment(app: app, sourceResult: nil, reports: [future], now: now).communityLeads.isEmpty)
    }

    func testMatchingIsRevokedWhenSourceIsRemovedFailsOrBelongsToAnotherApp() {
        let reports = [peer("2.0")]
        for sourceResult in [nil, result([source()], status: .failed), result([], status: .current),
                             .init(appID: "/other.app", candidates: [source()], note: "Wrong application", status: .updates)] as [SourceResult?] {
            let assessment = UpdateAssessment(app: app, sourceResult: sourceResult, reports: reports, now: now)
            XCTAssertFalse(assessment.hasUpdate)
            XCTAssertEqual(assessment.communityLeads.first?.confirmation, .unverified)
        }
        XCTAssertTrue(UpdateAssessment(app: app, sourceResult: result([source()], status: .partial), reports: reports, now: now).hasUpdate)
    }

    func testNotificationDedupIgnoresForgedCandidateAndRespectsSeenAndIgnoredApps() {
        let mixed = result([peer(), source()])
        let batch = UpdateAssessment.notificationBatch(apps: [app], results: [app.id: mixed], ignored: [], seen: [])
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.candidates.map(\.version), ["2.0"])
        XCTAssertEqual(batch.first?.deduplicationKeys, ["app.synthetic.trust:2.0:"])
        XCTAssertTrue(UpdateAssessment.notificationBatch(apps: [app], results: [app.id: mixed], ignored: [], seen: batch[0].deduplicationKeys).isEmpty)
        XCTAssertTrue(UpdateAssessment.notificationBatch(apps: [app], results: [app.id: mixed], ignored: [app.bundleID], seen: []).isEmpty)
    }

    func testStaleCurrentAndPrereleaseReportsCannotBecomeUpdates() {
        let assessment = UpdateAssessment(app: app, sourceResult: result([source("1.0"), source("0.9"), source("2.0-beta1")]),
            reports: [peer("1.0"), peer("0.9"), peer("2.0-beta1")], now: now)
        XCTAssertFalse(assessment.hasUpdate)
        XCTAssertTrue(assessment.communityLeads.isEmpty)
    }
}
