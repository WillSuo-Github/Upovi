import XCTest
@testable import UpoviCore

final class CommunityTests: XCTestCase {
    private func app(version: String = "2.0", team: String? = "TEST", appStore: Bool = false) -> InstalledApp {
        .init(name: "Fixture", bundleID: "app.test.public", version: version, path: "/fixture", teamID: team, isAppStore: appStore)
    }

    func testTopicsAreStableAcrossVersionsAndSeparateIdentities() {
        XCTAssertEqual(CommunityTopic.hash(app()), CommunityTopic.hash(app(version: "3.0")))
        XCTAssertNotEqual(CommunityTopic.hash(app()), CommunityTopic.hash(app(team: "OTHER")))
        XCTAssertNotEqual(CommunityTopic.hash(app()), CommunityTopic.hash(app(appStore: true)))
        XCTAssertNotEqual(CommunityTopic.hash(app(team: nil)), CommunityTopic.hash(app(team: "")))
        XCTAssertEqual(CommunityTopic.hash(app()).count, 20)
    }

    func testPublicReportRequiresNoInvitationButChecksSignatureAndApplication() throws {
        let own = PeerIdentity()
        let report = VersionReport(app: app())
        let record = try own.signPublic(report, sequence: 1)
        XCTAssertTrue(record.isValid)
        XCTAssertEqual(try CommunityTopic.decode(record, for: app(version: "1.0")), report)
        XCTAssertThrowsError(try CommunityTopic.decode(record, for: app(team: "OTHER")))
        XCTAssertThrowsError(try CommunityTopic.decode(record, for: app(appStore: true)))
        XCTAssertThrowsError(try CommunityTopic.decode(record, for: app(), now: Date().addingTimeInterval(25 * 3600)))
        var tampered = record; tampered.signature[0] ^= 1
        XCTAssertThrowsError(try CommunityTopic.decode(tampered, for: app()))
        let value = String(decoding: record.value.data!, as: UTF8.self)
        XCTAssertTrue(value.contains("app.test.public"))
        XCTAssertFalse(value.contains("/fixture"))
        XCTAssertLessThanOrEqual(record.value.encoded().count, 1000)
    }

    func testPrivateRecordsCannotBeReadAsPublicReports() throws {
        let record = try PeerIdentity().seal(VersionReport(app: app()), sequence: 1)
        XCTAssertThrowsError(try CommunityTopic.decode(record, for: app()))
    }

    func testPeerChallengeBindsEndpointTopicAndTime() throws {
        let report = try PeerIdentity().signPublic(VersionReport(app: app()), sequence: 10)
        let topic = CommunityTopic.hash(app())
        let responder = PublicPeerResponder(nodeID: Data(repeating: 1, count: 20), records: [topic: report])
        let endpoint = DHTEndpoint(host: "8.8.8.8", port: 54321)
        let now = Date()
        let hello: [String: BValue] = ["id": .bytes(Data(repeating: 2, count: 20)), "topic": .bytes(topic)]
        let token = try XCTUnwrap(responder.respond(method: "upovi_hello", args: hello, endpoint: endpoint, now: now)?["token"]?.data)
        XCTAssertEqual(token.count, 16)
        XCTAssertNil(responder.respond(method: "upovi_report", args: hello, endpoint: endpoint, now: now))
        var request = hello; request["token"] = .bytes(token)
        let response = try XCTUnwrap(responder.respond(method: "upovi_report", args: request, endpoint: endpoint, now: now))
        XCTAssertEqual(response["k"]?.data, report.publicKey)
        XCTAssertNil(responder.respond(method: "upovi_report", args: request, endpoint: .init(host: "8.8.8.8", port: 54322), now: now))
        XCTAssertNil(responder.respond(method: "upovi_report", args: request, endpoint: endpoint, now: now.addingTimeInterval(180)))
        request["topic"] = .bytes(Data(repeating: 3, count: 20))
        XCTAssertNil(responder.respond(method: "upovi_report", args: request, endpoint: endpoint, now: now))
        let off = PublicPeerResponder(nodeID: Data(repeating: 1, count: 20), records: [:])
        XCTAssertNil(off.respond(method: "upovi_hello", args: hello, endpoint: endpoint, now: now))
    }

    func testPeerContactsRejectPrivateAndMalformedAddresses() {
        for address in [[UInt8](arrayLiteral: 127,0,0,1), [10,0,0,1], [192,168,0,1], [198,18,0,1], [100,64,0,1], [100,127,255,254], [224,0,0,1]] {
            XCTAssertNil(DHTClient.parsePeer(Data(address + [26,225])))
        }
        XCTAssertNotNil(DHTClient.parsePeer(Data([8,8,8,8,26,225])))
        XCTAssertNil(DHTClient.parsePeer(Data([8,8,8,8,0,0])))
        XCTAssertNil(DHTClient.parsePeer(Data([8,8,8,8,1])))
    }

    func testDirectorySlotsRotateAndRejectPoisonedOrWrongShardValues() throws {
        let topic = CommunityTopic.hash(app())
        let publisher = PeerIdentity().invitation.publicKey
        let epoch = PublisherDirectorySlot.epoch()
        let shard = PublisherDirectorySlot.shard(for: publisher)
        let slot = PublisherDirectorySlot(topic: topic, epoch: epoch, shard: shard)
        let sequence = Int64(Date().timeIntervalSince1970 * 1000)
        let record = try slot.record(publishers: [publisher], sequence: sequence)
        XCTAssertEqual(slot.publishers(in: record), [publisher])
        XCTAssertLessThanOrEqual(record.value.encoded().count, 1000)
        let previous = PublisherDirectorySlot(topic: topic, epoch: epoch - 1, shard: shard)
        XCTAssertNotEqual(slot.publicKey, previous.publicKey)
        XCTAssertNil(previous.publishers(in: record))
        XCTAssertThrowsError(try slot.record(publishers: [publisher], sequence: Int64.max))
        let duplicate = try slot.record(publishers: [publisher, publisher], sequence: sequence)
        XCTAssertNil(slot.publishers(in: duplicate))
        // A rendezvous record (including its public coordination signature) is not a version report.
        XCTAssertThrowsError(try CommunityTopic.decode(record, for: app()))
        XCTAssertNotEqual(slot.publicKey, publisher)
    }
}
