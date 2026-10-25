import XCTest
@testable import UpoviCore

@MainActor
final class CommunityHistoryTests: XCTestCase {
    private func app(version: String = "2.0", team: String = "TEST") -> InstalledApp {
        .init(name: "Fixture", bundleID: "app.test.history", version: version, path: "/fixture", teamID: team)
    }

    private func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "upovi-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appending(path: "history.json")
    }

    func testReplayAndEquivocationRejectedAfterRestart() async throws {
        let url = try temporaryURL()
        let identity = PeerIdentity(), now = Date()
        let first = try identity.signPublic(.init(app: app(), now: now), sequence: 100)
        let second = try identity.signPublic(.init(app: app(version: "3.0"), now: now), sequence: 101)
        let initial = CommunityHistory(storageURL: url)
        _ = try await initial.accept(first, for: app(), now: now)
        _ = try await initial.accept(second, for: app(), now: now)
        let restarted = CommunityHistory(storageURL: url)
        do { _ = try await restarted.accept(first, for: app(), now: now); XCTFail("Replay accepted after restart") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Replayed")) }
        let conflicting = try identity.signPublic(.init(app: app(version: "99.0"), now: now), sequence: 101)
        do { _ = try await restarted.accept(conflicting, for: app(), now: now); XCTFail("Equivocation accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Conflicting")) }
        // Exact duplicates are harmless refreshes, not updates or new identities.
        let report = try await restarted.accept(second, for: app(), now: now)
        XCTAssertEqual(report.version, "3.0")
        let keys = try await restarted.knownPublishers(topic: CommunityTopic.hash(app()), now: now)
        XCTAssertEqual(keys, [identity.invitation.publicKey])
    }

    func testInvalidRecordsCannotPoisonPersistentHighWater() async throws {
        let url = try temporaryURL(), identity = PeerIdentity(), now = Date()
        let history = CommunityHistory(storageURL: url)
        let future = try identity.signPublic(.init(app: app(), now: now), sequence: Int64.max)
        let wrongTopic = try identity.signPublic(.init(app: app(team: "OTHER"), now: now), sequence: 1000)
        var tampered = try identity.signPublic(.init(app: app(), now: now), sequence: 1000)
        tampered.signature[0] ^= 1
        for invalid in [future, wrongTopic, tampered] {
            do { _ = try await history.accept(invalid, for: app(), now: now); XCTFail("Invalid record accepted") }
            catch { }
        }
        let valid = try identity.signPublic(.init(app: app(), now: now), sequence: 1)
        let report = try await history.accept(valid, for: app(), now: now)
        XCTAssertEqual(report.version, "2.0")
    }

    func testPublisherSequenceSurvivesRestartAndClockRollback() async throws {
        let url = try temporaryURL(), identity = PeerIdentity(), now = Date()
        let topic = CommunityTopic.hash(app()), key = identity.invitation.publicKey
        let first = try await CommunityHistory(storageURL: url).nextSequence(publicKey: key, topic: topic, now: now)
        let restarted = CommunityHistory(storageURL: url)
        let second = try await restarted.nextSequence(publicKey: key, topic: topic, now: now.addingTimeInterval(-60))
        XCTAssertEqual(second, first + 1)
        do {
            _ = try await restarted.nextSequence(publicKey: key, topic: topic, now: now.addingTimeInterval(-600))
            XCTFail("Large clock rollback accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("clock")) }
    }

    func testHistoryCorruptionAndWriteFailureFailClosed() async throws {
        let url = try temporaryURL(), identity = PeerIdentity()
        try Data("not-json".utf8).write(to: url)
        let broken = CommunityHistory(storageURL: url)
        do { _ = try await broken.knownPublishers(topic: CommunityTopic.hash(app())); XCTFail("Corruption silently reset history") }
        catch { }
        // A file in place of a parent directory makes persistence fail without relying on user permissions.
        let blocked = CommunityHistory(storageURL: url.appending(path: "child.json"))
        let record = try identity.signPublic(.init(app: app()), sequence: 1)
        do { _ = try await blocked.accept(record, for: app()); XCTFail("Unpersisted report accepted") }
        catch { }
    }

    func testHistoryRetentionAndTopicIsolation() async throws {
        let url = try temporaryURL(), identity = PeerIdentity(), now = Date()
        let history = CommunityHistory(storageURL: url)
        let record = try identity.signPublic(.init(app: app(), now: now), sequence: 10)
        _ = try await history.accept(record, for: app(), now: now)
        let unrelated = try await history.knownPublishers(topic: CommunityTopic.hash(app(team: "OTHER")), now: now)
        XCTAssertTrue(unrelated.isEmpty)
        let expired = try await history.knownPublishers(topic: record.salt, now: now.addingTimeInterval(CommunityHistory.retention + 1))
        XCTAssertTrue(expired.isEmpty)
    }

    func testCrowdedIndexCannotStarvePreviouslyValidatedPublisher() {
        let known = (1...6).map { Data(repeating: UInt8($0), count: 32) }
        let flood = (10...137).map { Data(repeating: UInt8($0), count: 32) }
        for _ in 0..<100 {
            let sampled = PublisherSampling.keys(known: known + known, advertised: flood, excluding: known[0])
            XCTAssertEqual(sampled.count, 8)
            XCTAssertEqual(Set(sampled).count, 8)
            XCTAssertEqual(sampled.filter { known.contains($0) }.count, 4)
            XCTAssertFalse(sampled.contains(known[0]))
        }
        let lone = known[0]
        XCTAssertTrue(PublisherSampling.keys(known: [lone], advertised: flood, excluding: nil).contains(lone))
        XCTAssertTrue(PublisherSampling.keys(known: [], advertised: [Data()], excluding: nil).isEmpty)
    }

    func testStopSharingInvalidatesPreparationAlreadyInProgress() async throws {
        let history = PausedPublicationHistory()
        let network = CommunityNetwork(dht: DHTClient(bootstrap: [], allowLocal: true), history: history)
        let application = app()
        let preparation = Task { try await network.prepare(apps: [application], sharingIdentity: PeerIdentity()) }
        await history.waitUntilPreparing()
        await network.stopSharing()
        await history.resume()
        do { try await preparation.value; XCTFail("Stopped generation resumed sharing") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await network.publish(application); XCTFail("Stopped record was still publishable") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not authorized")) }
    }
    func testGlobalStopInvalidatesPreparationAlreadyInProgress() async throws {
        let history = PausedPublicationHistory()
        let network = CommunityNetwork(dht: DHTClient(bootstrap: [], allowLocal: true), history: history)
        let application = app()
        let preparation = Task { try await network.prepare(apps: [application], sharingIdentity: PeerIdentity()) }
        await history.waitUntilPreparing()
        await network.stop()
        await history.resume()
        do { try await preparation.value; XCTFail("Disabled network resumed a delayed preparation") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await network.publish(application); XCTFail("Disabled network retained a publishable report") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not authorized")) }
    }
}

private actor PausedPublicationHistory: CommunityHistoryStore {
    private var pending: CheckedContinuation<Int64, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func nextSequence(publicKey: Data, topic: Data, now: Date) async throws -> Int64 {
        await withCheckedContinuation { continuation in
            pending = continuation
            entered?.resume(); entered = nil
        }
    }
    func waitUntilPreparing() async {
        if pending != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() { pending?.resume(returning: Int64(Date().timeIntervalSince1970 * 1000)); pending = nil }
    func knownPublishers(topic: Data, now: Date) async throws -> [Data] { [] }
    func accept(_ record: MutableRecord, for app: InstalledApp, now: Date) async throws -> VersionReport {
        try CommunityTopic.decode(record, for: app, now: now)
    }
}
