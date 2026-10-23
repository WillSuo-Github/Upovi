import Foundation
import CryptoKit

public protocol CommunityHistoryStore: Sendable {
    func knownPublishers(topic: Data, now: Date) async throws -> [Data]
    func accept(_ record: MutableRecord, for app: InstalledApp, now: Date) async throws -> VersionReport
    func nextSequence(publicKey: Data, topic: Data, now: Date) async throws -> Int64
}

/// Local replay protection, not a reputation system or proof of installation.
public actor CommunityHistory: CommunityHistoryStore {
    private struct Entry: Codable {
        let publicKey: Data
        let topic: Data
        let sequence: Int64
        let digest: Data
        let acceptedAt: Date
    }
    private struct State: Codable {
        var received: [String: Entry] = [:]
        var sent: [String: Int64] = [:]
    }
    private let storageURL: URL?
    private var state: State?
    static let retention: TimeInterval = 30 * 24 * 3600
    static let maximumEntries = 2048

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Upovi/community-history-v2.json")
    }

    /// A nil URL is an isolated in-memory history for diagnostics and tests.
    public init(storageURL: URL? = CommunityHistory.defaultURL) { self.storageURL = storageURL }

    private func load() throws -> State {
        if let state { return state }
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else {
            let empty = State(); state = empty; return empty
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else {
            throw PeerError.invalid("Community history exceeds the local storage limit")
        }
        let loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: storageURL))
        guard loaded.received.count <= Self.maximumEntries, loaded.sent.count <= Self.maximumEntries else {
            throw PeerError.invalid("Community history contains too many entries")
        }
        state = loaded
        return loaded
    }

    private func save(_ next: State) throws {
        if let storageURL {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: storageURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        }
        // Never advance memory if the disk write failed; callers must not display unpersisted observations.
        state = next
    }

    private func retained(_ entries: [String: Entry], now: Date) -> [String: Entry] {
        entries.filter { now.timeIntervalSince($0.value.acceptedAt) <= Self.retention }
    }

    public func knownPublishers(topic: Data, now: Date = Date()) throws -> [Data] {
        let loaded = try load()
        return retained(loaded.received, now: now).values.filter { $0.topic == topic }
            .sorted { $0.acceptedAt > $1.acceptedAt }.prefix(16).map(\.publicKey)
    }

    public func accept(_ record: MutableRecord, for app: InstalledApp, now: Date = Date()) throws -> VersionReport {
        // Invalid payloads must not advance a publisher's high-water mark.
        let report = try CommunityTopic.decode(record, for: app, now: now)
        var next = try load()
        next.received = retained(next.received, now: now)
        let id = record.target.base64EncodedString()
        let digest = Data(SHA256.hash(data: record.signable))
        if let previous = next.received[id] {
            guard record.sequence >= previous.sequence else { throw PeerError.invalid("Replayed community report rejected") }
            if record.sequence == previous.sequence {
                guard digest == previous.digest else { throw PeerError.invalid("Conflicting community report sequence rejected") }
                return report
            }
        }
        next.received[id] = Entry(publicKey: record.publicKey, topic: record.salt, sequence: record.sequence,
                                  digest: digest, acceptedAt: now)
        if next.received.count > Self.maximumEntries {
            let oldest = next.received.min { $0.value.acceptedAt < $1.value.acceptedAt }!.key
            next.received.removeValue(forKey: oldest)
        }
        try save(next)
        return report
    }

    public func nextSequence(publicKey: Data, topic: Data, now: Date = Date()) throws -> Int64 {
        guard publicKey.count == 32, topic.count == 20 else { throw PeerError.invalid("Invalid publication identity") }
        var next = try load()
        let id = Data(Insecure.SHA1.hash(data: publicKey + topic)).base64EncodedString()
        let previous = next.sent[id] ?? 0
        let ceiling = Int64(now.addingTimeInterval(300).timeIntervalSince1970 * 1000)
        guard previous < ceiling else { throw PeerError.invalid("Publication clock moved backwards; retry after clock recovery") }
        let sequence = max(Int64(now.timeIntervalSince1970 * 1000), previous + 1)
        // Sent marks are never silently evicted: reusing a sequence can strand a publisher in DHT storage.
        guard next.sent[id] != nil || next.sent.count < Self.maximumEntries else {
            throw PeerError.unavailable("Publication history is full")
        }
        next.sent[id] = sequence
        try save(next)
        return sequence
    }
}

enum PublisherSampling {
    /// Reserve half the budget for previously verified keys; open index writers cannot evict them from every lookup.
    static func keys(known: [Data], advertised: [Data], excluding ownKey: Data?) -> [Data] {
        func unique(_ keys: [Data]) -> [Data] {
            var seen = Set<Data>()
            return keys.filter { $0.count == 32 && $0 != ownKey && seen.insert($0).inserted }
        }
        let remembered = unique(known).shuffled()
        let fresh = unique(advertised).filter { !remembered.contains($0) }.shuffled()
        let reserved = Array(remembered.prefix(4))
        let new = Array(fresh.prefix(4))
        return Array((reserved + new + remembered.dropFirst(reserved.count) + fresh.dropFirst(new.count)).prefix(8))
    }
}
