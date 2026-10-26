import XCTest
@testable import UpoviCore

final class DiagnosticTests: XCTestCase {
    private let secret = "TOP_SECRET_DOWNLOAD_TOKEN"
    private var app: InstalledApp {
        .init(name: "Private machine app", bundleID: "dev.private.project", version: "1.2.3", build: "42",
              path: "/Users/private-owner/Work/Secret.app", teamID: "PRIVATEID1",
              feedURL: URL(string: "https://user:password@example.com/private?token=TOP_SECRET_DOWNLOAD_TOKEN"))
    }
    private func snapshot(events: [DiagnosticEvent] = [], count: Int = 1) -> DiagnosticSnapshot {
        let url = URL(string: "https://example.com/private?token=\(secret)")!
        let candidate = UpdateCandidate(version: "2", source: secret, isCommunity: false, url: url,
            download: .init(url: url, sha256: String(repeating: "a", count: 64)), releaseNotes: secret)
        let result = SourceResult(appID: app.id, candidates: [candidate], note: secret, status: .partial, manualURL: url,
            checks: [.init(.appcast, .failed, error: NSError(domain: NSURLErrorDomain, code: -1200,
                userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: url]))])
        let apps = (0..<count).map { index in index == 0 ? app : InstalledApp(name: secret, bundleID: "dev.extra.\(index)", version: "1", path: "/private/\(index).app") }
        return .init(applications: apps, results: [app.id: result], events: events,
            transactions: [.init(applicationID: app.id, kind: .administrator, state: .failed, date: .distantPast)],
            environment: .init(version: "0.4.5", build: "11", osMajor: 26, osMinor: 1, architecture: .arm64), online: true, busy: false)
    }
    func testDefaultReportProjectsNoInventoryPathsURLsFreeTextOrCredentials() throws {
        let event = DiagnosticEvent(applicationID: app.id, stage: .preparation,
            error: NSError(domain: secret, code: 99, userInfo: [NSLocalizedDescriptionKey: secret]))
        let data = try snapshot(events: [event]).report(), text = String(decoding: data, as: UTF8.self)
        for value in [secret, app.name, app.bundleID, app.path, app.teamID!, "example.com", "password", "private-owner", "1.2.3"] {
            XCTAssertFalse(text.contains(value), value)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try XCTUnwrap(object["applications"] as? [[String: Any]])
        XCTAssertEqual(apps.first?["reference"] as? String, "application-001")
        XCTAssertEqual(apps.first?["verifiableDownloadCount"] as? Int, 1)
        let transactions = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        XCTAssertEqual(transactions.first?["application"] as? String, "application-001")
        XCTAssertTrue(text.contains("tls")); XCTAssertTrue(text.contains("preparation"))
    }
    func testOptInOnlyAddsValidatedIdentifiersAndVersionsAndDefaultsResetPerReport() throws {
        let snapshot = snapshot()
        let identified = String(decoding: try snapshot.report(includingApplicationIdentifiers: true), as: UTF8.self)
        XCTAssertTrue(identified.contains(app.bundleID)); XCTAssertTrue(identified.contains(app.version))
        XCTAssertFalse(identified.contains(app.path)); XCTAssertFalse(identified.contains(secret)); XCTAssertFalse(identified.contains(app.name))
        XCTAssertFalse(String(decoding: try snapshot.report(), as: UTF8.self).contains(app.bundleID))
    }
    func testMalformedOptionalIdentityCannotSmuggleAPathOrURL() throws {
        let poisoned = InstalledApp(name: secret, bundleID: "https://example.com/?token=\(secret)", version: "/Users/\(secret)", build: "\n\(secret)", path: app.path)
        let snapshot = DiagnosticSnapshot(applications: [poisoned], results: [:], events: [], transactions: [],
            environment: .init(version: secret + "/", build: "secret\n", osMajor: 26, osMinor: 0, architecture: .arm64), online: false, busy: true)
        let text = String(decoding: try snapshot.report(includingApplicationIdentifiers: true), as: UTF8.self)
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("example.com")); XCTAssertTrue(text.contains("notChecked"))
    }
    func testErrorClassificationsNeverEncodeDescriptionsOrUserInfo() throws {
        let pairs: [(any Error, DiagnosticIssue.Kind)] = [
            (URLError(.notConnectedToInternet), .offline), (URLError(.timedOut), .timeout),
            (URLError(.secureConnectionFailed), .tls), (HTTPStatusError(statusCode: 429), .http),
            (CancellationError(), .cancelled), (PeerError.invalid(secret), .validationRejected), (PeerError.unavailable(secret), .operationFailed)
        ]
        for (error, kind) in pairs { let issue = DiagnosticIssue(error); XCTAssertEqual(issue.kind, kind); XCTAssertFalse(String(decoding: try JSONEncoder().encode(issue), as: UTF8.self).contains(secret)) }
        XCTAssertEqual(DiagnosticIssue(HTTPStatusError(statusCode: 429)).httpStatus, 429)
    }
    func testBoundsAndRemovedApplicationsDoNotLeakInternalKeys() throws {
        let events = (0..<55).map { _ in DiagnosticEvent(applicationID: "/deleted/\(secret)", stage: .recovery, error: URLError(.timedOut)) }
        let data = try snapshot(events: events, count: 1001).report()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual((object["applications"] as? [Any])?.count, 1000)
        XCTAssertEqual((object["recentIssues"] as? [Any])?.count, 50)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
    }
}
