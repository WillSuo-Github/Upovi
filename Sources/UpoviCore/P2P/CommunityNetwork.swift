import Foundation
import CryptoKit

public struct CommunityObservation: Identifiable, Sendable {
    public let publicKey: Data
    public let report: VersionReport
    public var id: String { publicKey.base64EncodedString() }
    public var shortID: String { Data(SHA256.hash(data: publicKey)).prefix(6).map { String(format: "%02x", $0) }.joined() }
}

public struct CommunityDiscovery: Sendable {
    public let observations: [CommunityObservation]
    public let endpoints: Int
    public let unreachable: Int
    public let directoryCandidates: Int
    public let failedRecords: Int
    public let responders: Int
    public let rejectedReports: Int
    public let dhtPublishers: Int
    public let directPublishers: Int
}

/// Public discovery does not consume invitation keys or expose private v1 records.
public actor CommunityNetwork {
    private let dht: DHTClient
    private let history: any CommunityHistoryStore
    private var ownKey: Data?
    private var records: [Data: MutableRecord] = [:]
    private var sharingGeneration: UInt64 = 0

    public init(dht: DHTClient = DHTClient(), history: any CommunityHistoryStore = CommunityHistory()) {
        self.dht = dht; self.history = history
    }

    public func prepare(apps: [InstalledApp], sharingIdentity: PeerIdentity?) async throws {
        sharingGeneration &+= 1
        let generation = sharingGeneration
        var next: [Data: MutableRecord] = [:]
        if let sharingIdentity {
            ownKey = sharingIdentity.invitation.publicKey
            for app in apps.prefix(20) {
                try Task.checkCancellation()
                let topic = CommunityTopic.hash(app)
                let sequence = try await history.nextSequence(publicKey: sharingIdentity.invitation.publicKey, topic: topic, now: Date())
                guard generation == sharingGeneration else { throw CancellationError() }
                next[topic] = try sharingIdentity.signPublic(.init(app: app), sequence: sequence)
            }
        }
        try Task.checkCancellation()
        guard generation == sharingGeneration else { throw CancellationError() }
        try await dht.servePublicRecords(next)
        guard generation == sharingGeneration else { throw CancellationError() }
        records = next
    }

    public func resetRouting() async { await dht.resetRouting() }

    public func resume() async { await dht.resume() }

    public func stop() async {
        sharingGeneration &+= 1
        records = [:]; ownKey = nil
        await dht.suspend()
    }

    public func stopSharing() async {
        sharingGeneration &+= 1
        records = [:]
        try? await dht.servePublicRecords([:])
    }

    public func publish(_ app: InstalledApp) async throws -> (announcements: Int, storage: Int, directory: Int) {
        let topic = CommunityTopic.hash(app)
        guard let record = records[topic] else { throw PeerError.invalid("Application is not authorized for public sharing") }
        let storage = (try? await dht.publishPublic(record)) ?? 0
        try Task.checkCancellation()
        guard records[topic]?.sequence == record.sequence else { throw CancellationError() }
        let directory = (try? await dht.registerPublisher(publicKey: record.publicKey, topic: topic)) ?? 0
        try Task.checkCancellation()
        guard records[topic]?.sequence == record.sequence else { throw CancellationError() }
        let discovery = try? await dht.announce(infoHash: topic)
        guard directory > 0 || (discovery?.announcements ?? 0) > 0 else { throw PeerError.unavailable("No public discovery registration was acknowledged") }
        return (discovery?.announcements ?? 0, storage, directory)
    }

    public func discover(_ app: InstalledApp, cachedKeys: [Data] = []) async throws -> CommunityDiscovery {
        let topic = CommunityTopic.hash(app)
        async let directoryLookup = try? dht.discoverPublishers(topic: topic)
        async let swarmLookup = try? dht.discover(infoHash: topic)
        let (directory, swarm) = await (directoryLookup, swarmLookup)
        try Task.checkCancellation()
        var observations: [Data: CommunityObservation] = [:]
        var dhtPublishers = Set<Data>(), directPublishers = Set<Data>()
        var failedRecords = 0, unreachable = 0, rejectedReports = 0
        let known = try await history.knownPublishers(topic: topic, now: Date())
        guard directory != nil || swarm != nil || !known.isEmpty || !cachedKeys.isEmpty else {
            throw PeerError.unavailable("Neither public discovery path responded and no verified publisher is remembered")
        }
        let keys = PublisherSampling.keys(known: known + cachedKeys, advertised: directory?.keys ?? [], excluding: ownKey)
        // Directory pointers are never trusted as reports. Every observation must be
        // independently signed by the advertised publisher key and match this app.
        for start in stride(from: 0, to: min(keys.count, 8), by: 4) {
            try Task.checkCancellation()
            let batch = Array(keys[start..<min(start + 4, min(keys.count, 8))])
            let fetched = await withTaskGroup(of: MutableRecord?.self) { group in
                for key in batch {
                    group.addTask {
                        (try? await self.dht.lookup(publicKey: key, salt: topic, trackHighWater: false,
                            accepting: { (try? CommunityTopic.decode($0, for: app)) != nil }))?.record
                    }
                }
                var records: [MutableRecord?] = []
                for await record in group { records.append(record) }
                return records
            }
            for record in fetched {
                guard let record else { failedRecords += 1; continue }
                do {
                    let report = try await history.accept(record, for: app, now: Date())
                    observations[record.publicKey] = .init(publicKey: record.publicKey, report: report)
                    dhtPublishers.insert(record.publicKey)
                } catch {
                    if case PeerError.invalid = error { rejectedReports += 1 }
                    else { throw error }
                }
            }
        }
        // Always sample the independent peer path. One valid index report must not suppress fresher direct reports.
        do {
            let endpoints = Array((swarm?.peers ?? []).shuffled().prefix(12))
            for chunk in stride(from: 0, to: endpoints.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(endpoints[chunk..<min(chunk + 4, endpoints.count)])
                let fetched = await withTaskGroup(of: MutableRecord?.self) { group in
                    for endpoint in batch { group.addTask { try? await self.dht.requestPublicRecord(endpoint: endpoint, topic: topic) } }
                    var records: [MutableRecord?] = []
                    for await record in group { records.append(record) }
                    return records
                }
                for record in fetched {
                    guard let record else { unreachable += 1; continue }
                    if record.publicKey == ownKey { continue }
                    do {
                        let report = try await history.accept(record, for: app, now: Date())
                        observations[record.publicKey] = .init(publicKey: record.publicKey, report: report)
                        directPublishers.insert(record.publicKey)
                    } catch {
                        if case PeerError.invalid = error { rejectedReports += 1 }
                        else { throw error }
                    }
                }
            }
        }
        try Task.checkCancellation()
        return .init(observations: Array(observations.values), endpoints: swarm?.peers.count ?? 0,
            unreachable: unreachable, directoryCandidates: directory?.keys.count ?? 0, failedRecords: failedRecords,
            responders: (directory?.responders ?? 0) + (swarm?.responders ?? 0), rejectedReports: rejectedReports,
            dhtPublishers: dhtPublishers.count, directPublishers: directPublishers.count)
    }
}
