import XCTest
import CryptoKit
@testable import UpoviCore

final class CoreTests: XCTestCase {
    func testVersionsRespectNumericComponentsAndPrereleases() {
        XCTAssertEqual(VersionOrder.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(VersionOrder.compare("v1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(VersionOrder.compare("2.0rc1", "2.0beta9"), .orderedDescending)
        XCTAssertEqual(VersionOrder.compare("2.0", "2.0rc5"), .orderedDescending)
        XCTAssertNil(VersionOrder.compare("2026 Spring Edition", "latest"))
        let app = InstalledApp(name: "Fixture", bundleID: "app.fixture", version: "1.0", build: "100", path: "/fixture")
        XCTAssertFalse(VersionOrder.isNewer(version: "2.0beta1", than: app))
        XCTAssertTrue(VersionOrder.isNewer(version: "1.0", build: "101", than: app))
        XCTAssertFalse(VersionOrder.isNewer(version: "1.0", build: "99", than: app))
        // Homebrew's "short.build" spelling of the installed version is not an update.
        let thunder = InstalledApp(name: "Thunder", bundleID: "com.xunlei.Thunder", version: "5.80.8", build: "66675", path: "/fixture")
        XCTAssertFalse(VersionOrder.isNewer(version: "5.80.8.66675", than: thunder))
        XCTAssertTrue(VersionOrder.isNewer(version: "5.80.8.66676", than: thunder))
        XCTAssertTrue(VersionOrder.isNewer(version: "5.80.9", than: thunder))
    }

    func testBencodeRejectsMalformedAndAmbiguousPackets() throws {
        let value = BValue.dict(["v": .bytes(Data([0, 255, 128])), "seq": .int(12), "a": .list([.string("ok"), .int(-2)])])
        XCTAssertEqual(try BValue.decode(value.encoded()), value)
        for invalid in ["i-0e", "i03e", "03:abc", "4:abc", "degarbage", "d1:ai1e1:ai2ee", "d1:bi1e1:ai2ee", "li1e"] {
            XCTAssertThrowsError(try BValue.decode(Data(invalid.utf8)), invalid)
        }
        XCTAssertThrowsError(try BValue.decode(Data(repeating: 108, count: 30)))
        XCTAssertNoThrow(try BValue.decode(Data("d1:bi1e1:ai2ee".utf8), strict: false))
        XCTAssertThrowsError(try BValue.decode(Data("d1:ai1e1:ai2ee".utf8), strict: false))
    }

    func testBEP44SignableCanonicalForm() {
        let record = MutableRecord(publicKey: Data(repeating: 0, count: 32), salt: Data("foobar".utf8), sequence: 4,
                                   value: .string("Hello world!"), signature: Data())
        XCTAssertEqual(String(decoding: record.signable, as: UTF8.self), "4:salt6:foobar3:seqi4e1:v12:Hello world!")
        XCTAssertEqual(record.target.count, 20)
    }

    func testSignedEncryptedRecordAndInvitationRoundTrip() throws {
        let owner = PeerIdentity()
        let invite = try PeerInvitation(url: owner.invitation.url)
        XCTAssertEqual(invite.publicKey, owner.invitation.publicKey)
        XCTAssertEqual(invite.readKey, owner.invitation.readKey)
        let app = InstalledApp(name: "Secret app name", bundleID: "app.fixture", version: "2.4.1", build: "12", path: "/Users/private/Secret.app", teamID: "TEST")
        let report = VersionReport(app: app)
        let sealed = try owner.seal(report, sequence: 42)
        XCTAssertTrue(sealed.isValid)
        XCTAssertLessThanOrEqual(sealed.value.encoded().count, 1000)
        let opened = try VersionReport.open(sealed, from: invite, bundleID: app.bundleID, channel: app.channel)
        XCTAssertEqual(opened, report)
        XCTAssertFalse(String(decoding: sealed.value.encoded(), as: UTF8.self).contains(app.bundleID))
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/Users")); XCTAssertFalse(encoded.contains("Secret app name"))
        XCTAssertThrowsError(try VersionReport.open(sealed, from: invite, bundleID: "other.app", channel: app.channel))
        XCTAssertThrowsError(try VersionReport.open(sealed, from: invite, bundleID: app.bundleID, channel: "app-store"))
        let stranger = PeerIdentity().invitation
        XCTAssertThrowsError(try VersionReport.open(sealed, from: stranger, bundleID: app.bundleID, channel: app.channel))
    }

    func testRejectTamperedExpiredAndWrongDecryptionKey() throws {
        let owner = PeerIdentity()
        let app = InstalledApp(name: "Test", bundleID: "app.fixture", version: "2.0", path: "/test")
        let report = VersionReport(app: app)
        var sealed = try owner.seal(report, sequence: 3)
        let wrongKey = PeerInvitation(name: "Wrong", publicKey: owner.invitation.publicKey, readKey: PeerIdentity().invitation.readKey)
        XCTAssertThrowsError(try VersionReport.open(sealed, from: wrongKey, bundleID: app.bundleID, channel: app.channel))
        XCTAssertThrowsError(try VersionReport.open(sealed, from: owner.invitation, bundleID: app.bundleID, channel: app.channel, now: Date().addingTimeInterval(25 * 3600)))
        sealed.signature[0] ^= 1
        XCTAssertFalse(sealed.isValid)
        XCTAssertThrowsError(try VersionReport.open(sealed, from: owner.invitation, bundleID: app.bundleID, channel: app.channel))
        XCTAssertThrowsError(try owner.seal(VersionReport(app: app, now: Date().addingTimeInterval(-25 * 3600)), sequence: 4))
    }

    func testInvalidInvitations() {
        for text in ["https://example.com", "upovi://peer?v=1&key=bad&read=bad", "upovi://peer?v=99", "upovi://join"] {
            XCTAssertThrowsError(try PeerInvitation(url: text))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PeerIdentity.self, from: Data(#"{"signingKey":"AA==","readKey":"AA=="}"#.utf8)))
    }

    func testAppcastSkipsBetaAndIncompatibleSystem() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><link>https://example.com/release</link>
        <enclosure sparkle:version="240" sparkle:shortVersionString="2.4" url="https://example.com/app.zip" /></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="250" sparkle:shortVersionString="2.5beta1" /></item>
        <item><sparkle:minimumSystemVersion>999.0</sparkle:minimumSystemVersion><enclosure sparkle:version="300" sparkle:shortVersionString="3.0" /></item>
        </channel></rss>
        """
        let items = try AppcastReader.read(Data(xml.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.version, "2.4")
        XCTAssertEqual(items.first?.build, "240")
        XCTAssertEqual(items.first?.url?.host, "example.com")
        XCTAssertThrowsError(try AppcastReader.read(Data("<rss>".utf8)))
    }

    func testScannerReadsMetadataWithoutExecutingApplications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Fixture.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "app.test.fixture", "CFBundleName": "Fixture", "CFBundleShortVersionString": "1.2", "CFBundleVersion": "10", "SUFeedURL": "http://insecure.example/feed"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let apps = AppScanner.scan(roots: [root])
        XCTAssertEqual(apps.count, 1); XCTAssertEqual(apps.first?.version, "1.2"); XCTAssertNil(apps.first?.feedURL)
    }

    func testCompactNodesRejectTruncationAndPrivateDestinations() {
        let node = Data(repeating: 0, count: 20) + Data([127, 0, 0, 1, 26, 225])
        XCTAssertTrue(DHTClient.parseNodes(node).isEmpty)
        XCTAssertEqual(DHTClient.parseNodes(node, allowLocal: true).first?.endpoint.port, 6881)
        XCTAssertTrue(DHTClient.parseNodes(node.dropLast()).isEmpty)
        let publicNode = Data(repeating: 1, count: 20) + Data([8, 8, 8, 8, 26, 225])
        XCTAssertEqual(DHTClient.parseNodes(publicNode).count, 1)
    }
}
