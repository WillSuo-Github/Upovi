import Foundation
import CryptoKit

/// An explicitly untrusted, rotating rendezvous directory. The deterministic slot
/// key is public coordination material, NOT a publisher identity or trust anchor.
struct PublisherDirectorySlot: Sendable {
    static let shardCount = 4
    static let epochSeconds: Int64 = 3600
    static let salt = Data("upovi-index-v2".utf8)
    let topic: Data
    let epoch: Int64
    let shard: Int

    static func epoch(at date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970) / epochSeconds }
    static func shard(for key: Data) -> Int { Int(Array(SHA256.hash(data: key))[0]) % shardCount }

    private var key: Curve25519.Signing.PrivateKey {
        let address = BValue.list([.string("app.upovi.public-rendezvous.v2"), .bytes(topic), .int(epoch), .int(Int64(shard))]).encoded()
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: address)))
    }
    var publicKey: Data { key.publicKey.rawRepresentation }
    var maximumSequence: Int64 { (epoch + 1) * Self.epochSeconds * 1000 + 300_000 }

    func publishers(in record: MutableRecord) -> [Data]? {
        guard record.publicKey == publicKey, record.salt == Self.salt, record.isValid,
              record.sequence >= epoch * Self.epochSeconds * 1000, record.sequence <= maximumSequence,
              case let .list(values) = record.value, values.count <= 16 else { return nil }
        let keys = values.compactMap(\.data)
        guard keys.count == values.count, keys.allSatisfy({ $0.count == 32 && Self.shard(for: $0) == shard }),
              Set(keys).count == keys.count else { return nil }
        return keys
    }

    func record(publishers: [Data], sequence: Int64) throws -> MutableRecord {
        guard publishers.count <= 16, sequence <= maximumSequence else { throw PeerError.invalid("Invalid directory update") }
        var record = MutableRecord(publicKey: publicKey, salt: Self.salt, sequence: sequence,
                                   value: .list(publishers.map(BValue.bytes)), signature: Data())
        record.signature = try key.signature(for: record.signable)
        return record
    }
}

public struct PublisherDirectoryResult: Sendable {
    public let keys: [Data]
    public let responders: Int
    public let failedSlots: Int
}
