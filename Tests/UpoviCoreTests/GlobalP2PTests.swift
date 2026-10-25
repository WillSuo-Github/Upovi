import XCTest
import Darwin
@testable import UpoviCore

final class GlobalP2PTests: XCTestCase {
    private func app(_ index: Int, version: String = "1.0", team: String? = "SYNTHETIC", store: Bool = false, path: String? = nil) -> InstalledApp {
        .init(name: "Fixture \(index)", bundleID: "app.upovi.synthetic.global.\(index)", version: version,
              path: path ?? "/synthetic/\(index).app", teamID: team, isAppStore: store)
    }
    func testFreshInstallDefaultsToOneEnabledPreference() {
        let values = GlobalP2PSettings.migrated([:], existingInstallation: false)
        XCTAssertEqual(GlobalP2PSettings.storedEnabled(in: values), true)
        XCTAssertEqual(values.count, 1)
    }
    func testExistingOffAndOldAppSpecificConsentAreNotExpandedOnUpgrade() {
        for old in [[String: Any](), ["publicDiscoveryEnabledV2": false, "publicSharingEnabledV2": false],
                    ["publicDiscoveryEnabledV2": true, "publicSharingEnabledV2": true, "selectedBundles": ["app.one"]]] {
            let migrated = GlobalP2PSettings.migrated(old, existingInstallation: true)
            XCTAssertEqual(GlobalP2PSettings.storedEnabled(in: migrated), false)
            for key in GlobalP2PSettings.legacyKeys { XCTAssertNil(migrated[key]) }
        }
        let explicit: [String: Any] = [GlobalP2PSettings.key: true, "selectedBundles": ["app.one"], "publicSharingEnabledV2": false]
        XCTAssertEqual(GlobalP2PSettings.storedEnabled(in: GlobalP2PSettings.migrated(explicit, existingInstallation: true)), true)
        XCTAssertEqual(GlobalP2PSettings.storedEnabled(in: GlobalP2PSettings.migrated([GlobalP2PSettings.key: false], existingInstallation: false)), false)
    }
    func testMalformedPreferenceNeverEnablesPublicSharing() throws {
        let invalid: [Any] = ["true", 1, NSNumber(value: 1), Data([1])]
        for value in invalid {
            let encoded = try PropertyListSerialization.data(fromPropertyList: [GlobalP2PSettings.key: value], format: .binary, options: 0)
            let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
            XCTAssertEqual(GlobalP2PSettings.storedEnabled(in: GlobalP2PSettings.migrated(decoded, existingInstallation: false)), false)
        }
    }
    func testAllApplicationsAreCoveredAcrossBoundedBatches() {
        let all = (0..<73).map { app($0) }
        let scope = GlobalP2PScope.applications(all)
        XCTAssertEqual(scope.map(\.id), GlobalP2PScope.applications(Array(all.reversed())).map(\.id))
        var offset = 0, visited: [String] = [], counts: [Int] = []
        repeat {
            let batch = GlobalP2PScope.batch(scope, offset: offset)
            counts.append(batch.apps.count); visited += batch.apps.map(\.id); offset = batch.nextOffset
        } while offset != 0
        XCTAssertEqual(counts, [20, 20, 20, 13])
        XCTAssertEqual(visited, scope.map(\.id))
        XCTAssertTrue(GlobalP2PScope.batch([], offset: 100).apps.isEmpty)
    }
    func testScopeKeepsNewestCopyAndSeparatesDeveloperAndChannel() {
        let old = app(1, path: "/synthetic/old.app"), newer = app(1, version: "2.0", path: "/synthetic/new.app")
        let otherDeveloper = app(1, team: "ANOTHER"), appStore = app(1, store: true)
        let scope = GlobalP2PScope.applications([old, newer, otherDeveloper, appStore])
        XCTAssertEqual(scope.count, 3)
        XCTAssertTrue(scope.contains { $0.path == newer.path }); XCTAssertFalse(scope.contains { $0.path == old.path })
    }
    func testClosingTransportCancelsPendingWorkAndReleasesItsPort() async throws {
        let transport = try DHTSocket(), port = transport.port
        let pending = Task { try await transport.query(Data([1]), transaction: Data([2]), endpoint: .init(host: "127.0.0.1", port: 9), timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        await transport.close()
        do { _ = try await pending.value; XCTFail("Closed socket retained a pending request") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await transport.query(Data([1]), transaction: Data([3]), endpoint: .init(host: "127.0.0.1", port: 9)); XCTFail("Closed socket reopened") }
        catch { XCTAssertTrue(error is CancellationError) }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
    }
    func testFullStopPreventsServingUntilExplicitResume() async throws {
        let client = DHTClient(bootstrap: [], allowLocal: true), network = CommunityNetwork(dht: client)
        let app = app(0), record = try PeerIdentity().signPublic(.init(app: app), sequence: 1)
        try await client.servePublicRecords([CommunityTopic.hash(app): record])
        await network.stop()
        do { try await client.servePublicRecords([CommunityTopic.hash(app): record]); XCTFail("Disabled client opened a socket") }
        catch { XCTAssertTrue(error is CancellationError) }
        await network.resume()
        try await client.servePublicRecords([CommunityTopic.hash(app): record])
        await network.stop()
    }
}
