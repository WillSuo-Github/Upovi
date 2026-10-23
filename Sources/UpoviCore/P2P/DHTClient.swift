import Foundation
import CryptoKit

public struct DHTNode: Hashable, Sendable {
    public let id: Data
    public let endpoint: DHTEndpoint
}

public struct DHTLookup: Sendable {
    public let record: MutableRecord?
    public let records: [MutableRecord]
    public let responders: Int
    fileprivate let stores: [DHTStore]
}

private struct DHTStore: Sendable { let node: DHTNode; let token: Data; let sequence: Int64? }
private struct DHTWalk: Sendable {
    let responses: [[String: BValue]]
    let stores: [DHTStore]
    let responders: Int
}

public struct SwarmDiscovery: Sendable {
    public let peers: [DHTEndpoint]
    public let responders: Int
    public var announcements: Int = 0
}

public actor DHTClient {
    public static let publicBootstrap = [DHTEndpoint(host: "router.bt.ouinet.work", port: 6881),
                                          DHTEndpoint(host: "dht.transmissionbt.com", port: 6881),
                                          DHTEndpoint(host: "dht.libtorrent.org", port: 25401)]
    private let nodeID = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
    private let bootstrap: [DHTEndpoint]
    private let allowLocal: Bool
    private var socket: DHTSocket?
    private var known: [DHTNode] = []
    private var highWater: [Data: Int64] = [:]

    public init(bootstrap: [DHTEndpoint] = DHTClient.publicBootstrap, allowLocal: Bool = false) {
        self.bootstrap = bootstrap; self.allowLocal = allowLocal
    }

    public func resetRouting() async {
        if let socket { await socket.setHandler(nil) }
        socket = nil; known = []
    }

    private func datagramSocket() throws -> DHTSocket {
        if let socket { return socket }
        let created = try DHTSocket(); socket = created
        return created
    }

    public func lookup(publicKey: Data, salt: Data, maximumSequence: Int64? = nil, trackHighWater: Bool = true,
                       accepting: @Sendable (MutableRecord) -> Bool = { _ in true }) async throws -> DHTLookup {
        guard publicKey.count == 32, salt.count <= 64 else { throw PeerError.invalid("Invalid DHT key") }
        let target = Data(Insecure.SHA1.hash(data: publicKey + salt))
        let walk = try await walk(target: target, method: "get")
        let records = walk.responses.compactMap { Self.record($0, salt: salt) }.filter {
            $0.publicKey == publicKey && $0.target == target && $0.isValid &&
            $0.sequence >= (trackHighWater ? highWater[target] ?? -1 : -1) && $0.sequence <= (maximumSequence ?? Int64.max) && accepting($0)
        }
        let newest = records.max { $0.sequence < $1.sequence }
        if let newest, trackHighWater { highWater[target] = newest.sequence }
        return .init(record: newest, records: records, responders: walk.responders, stores: walk.stores)
    }

    public func discover(infoHash: Data) async throws -> SwarmDiscovery {
        let result = try await swarm(infoHash: infoHash)
        return result.0
    }

    /// The same bound UDP port sends get_peers and announce_peer, so implied_port
    /// registers the NAT-observed port rather than an unrelated ephemeral socket.
    public func announce(infoHash: Data) async throws -> SwarmDiscovery {
        let (discovery, stores) = try await swarm(infoHash: infoHash)
        try Task.checkCancellation()
        let localPort = try datagramSocket().port
        let id = nodeID
        let count = await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask {
                    (try? await self.rpc("announce_peer", args: ["id": .bytes(id), "info_hash": .bytes(infoHash),
                        "port": .int(Int64(localPort)), "implied_port": .int(1), "token": .bytes(store.token)], endpoint: store.node.endpoint)) != nil
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        guard count > 0 else { throw PeerError.unavailable("No DHT nodes acknowledged the peer announcement") }
        return .init(peers: discovery.peers, responders: discovery.responders, announcements: count)
    }

    private func swarm(infoHash: Data) async throws -> (SwarmDiscovery, [DHTStore]) {
        guard infoHash.count == 20 else { throw PeerError.invalid("Invalid application topic") }
        let result = try await walk(target: infoHash, method: "get_peers")
        var peers = Set<DHTEndpoint>()
        for response in result.responses {
            if case let .list(values) = response["values"] {
                for value in values {
                    if let compact = value.data, let peer = Self.parsePeer(compact, allowLocal: allowLocal) { peers.insert(peer) }
                }
            }
        }
        let sorted = peers.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
        return (.init(peers: Array(sorted.prefix(64)), responders: result.responders), result.stores)
    }

    private func walk(target: Data, method: String) async throws -> DHTWalk {
        var pool = Dictionary(known.map { ($0.endpoint, $0) }, uniquingKeysWith: { a, _ in a })
        var queried = Set<DHTEndpoint>()
        var stores: [DHTStore] = []
        var responses: [[String: BValue]] = []
        let id = nodeID
        let localAllowed = allowLocal
        if pool.isEmpty {
            let seeds = await withTaskGroup(of: [DHTNode].self) { group in
                for endpoint in bootstrap {
                    group.addTask {
                        guard let response = try? await self.rpc("find_node", args: ["id": .bytes(id), "target": .bytes(target)], endpoint: endpoint) else { return [] }
                        var nodes = Self.parseNodes(response["nodes"]?.data ?? Data(), allowLocal: localAllowed)
                        if let remoteID = response["id"]?.data, remoteID.count == 20 { nodes.append(.init(id: remoteID, endpoint: endpoint)) }
                        return nodes
                    }
                }
                var nodes: [DHTNode] = []
                for await batch in group { nodes += batch }
                return nodes
            }
            for node in seeds { pool[node.endpoint] = node }
        }
        for round in 0..<12 {
            try Task.checkCancellation()
            let endpoints = round == 0 && pool.isEmpty ? bootstrap : pool.values.filter { !queried.contains($0.endpoint) }
                .sorted { Self.closer($0.id, $1.id, target: target) }.prefix(5).map(\.endpoint)
            if endpoints.isEmpty { break }
            queried.formUnion(endpoints)
            let replies = await withTaskGroup(of: (DHTEndpoint, [String: BValue]?).self) { group in
                for endpoint in endpoints {
                    group.addTask {
                        let args: [String: BValue] = ["id": .bytes(id), method == "get_peers" ? "info_hash" : "target": .bytes(target)]
                        return (endpoint, try? await self.rpc(method, args: args, endpoint: endpoint))
                    }
                }
                var results: [(DHTEndpoint, [String: BValue]?)] = []
                for await reply in group { results.append(reply) }
                return results
            }
            for (endpoint, response) in replies {
                guard let response, let remoteID = response["id"]?.data, remoteID.count == 20 else { continue }
                responses.append(response)
                let node = DHTNode(id: remoteID, endpoint: endpoint); pool[endpoint] = node
                if let token = response["token"]?.data, !token.isEmpty, token.count <= 128 {
                    stores.append(.init(node: node, token: token, sequence: response["seq"]?.integer))
                }
                for node in Self.parseNodes(response["nodes"]?.data ?? Data(), allowLocal: localAllowed) {
                    if pool.count < 512 { pool[node.endpoint] = node }
                }
            }
            let closest = pool.values.sorted { Self.closer($0.id, $1.id, target: target) }.prefix(8)
            if round >= 2, closest.count >= 8, closest.allSatisfy({ queried.contains($0.endpoint) }) { break }
        }
        try Task.checkCancellation()
        guard !responses.isEmpty else {
            known = []
            throw PeerError.unavailable("No valid DHT responses. Check UDP connectivity.")
        }
        known = Array(pool.values.sorted { Self.closer($0.id, $1.id, target: target) }.prefix(160))
        return .init(responses: responses, stores: Array(stores.sorted { Self.closer($0.node.id, $1.node.id, target: target) }.prefix(8)), responders: responses.count)
    }

    public func publish(identity: PeerIdentity, report: VersionReport) async throws -> Int {
        let peer = identity.invitation
        let salt = peer.salt(bundleID: report.bundleID, channel: report.channel)
        let lookup = try await lookup(publicKey: peer.publicKey, salt: salt)
        let target = Data(Insecure.SHA1.hash(data: peer.publicKey + salt))
        let previous = max(lookup.record?.sequence ?? 0, highWater[target] ?? 0)
        guard previous < Int64.max else { throw PeerError.invalid("DHT sequence exhausted") }
        return try await store(identity.seal(report, sequence: max(Int64(Date().timeIntervalSince1970 * 1000), previous + 1)), stores: lookup.stores)
    }

    public func publishPublic(_ record: MutableRecord) async throws -> Int {
        guard record.isValid else { throw PeerError.invalid("Invalid public report") }
        let result = try await lookup(publicKey: record.publicKey, salt: record.salt)
        return try await store(record, stores: result.stores)
    }

    private func store(_ record: MutableRecord, stores: [DHTStore], compareAndSwap: Bool = false) async throws -> Int {
        try Task.checkCancellation()
        let id = nodeID
        let count = await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask {
                    var args: [String: BValue] = ["id": .bytes(id), "token": .bytes(store.token), "k": .bytes(record.publicKey),
                        "salt": .bytes(record.salt), "seq": .int(record.sequence), "sig": .bytes(record.signature), "v": record.value]
                    if compareAndSwap, let previous = store.sequence { args["cas"] = .int(previous) }
                    return (try? await self.rpc("put", args: args, endpoint: store.node.endpoint)) != nil
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        guard count > 0 else { throw PeerError.unavailable("No DHT nodes acknowledged record storage") }
        if !compareAndSwap { highWater[record.target] = max(highWater[record.target] ?? 0, record.sequence) }
        return count
    }

    public func registerPublisher(publicKey: Data, topic: Data) async throws -> Int {
        guard publicKey.count == 32, topic.count == 20 else { throw PeerError.invalid("Invalid publisher registration") }
        let slot = PublisherDirectorySlot(topic: topic, epoch: PublisherDirectorySlot.epoch(), shard: PublisherDirectorySlot.shard(for: publicKey))
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let lookup = try await lookup(publicKey: slot.publicKey, salt: PublisherDirectorySlot.salt,
                                          maximumSequence: slot.maximumSequence, trackHighWater: false,
                                          accepting: { slot.publishers(in: $0) != nil })
            let previous = Array(Set(lookup.records.flatMap { slot.publishers(in: $0) ?? [] }))
            let keys = [publicKey] + Array(previous.filter { $0 != publicKey }.shuffled().prefix(15))
            let sequence = max(Int64(Date().timeIntervalSince1970 * 1000), (lookup.record?.sequence ?? 0) + 1)
            let record = try slot.record(publishers: keys, sequence: sequence)
            do { return try await store(record, stores: lookup.stores, compareAndSwap: true) }
            catch { if attempt == 2 || Task.isCancelled { throw error } }
        }
        throw PeerError.unavailable("Public rendezvous registration failed")
    }

    public func discoverPublishers(topic: Data) async throws -> PublisherDirectoryResult {
        guard topic.count == 20 else { throw PeerError.invalid("Invalid directory topic") }
        let epoch = PublisherDirectorySlot.epoch()
        let results = await withTaskGroup(of: ([Data], Int).self) { group in
            for window in [epoch, epoch - 1] {
                for shard in 0..<PublisherDirectorySlot.shardCount {
                    group.addTask {
                        let slot = PublisherDirectorySlot(topic: topic, epoch: window, shard: shard)
                        guard let result = try? await self.lookup(publicKey: slot.publicKey, salt: PublisherDirectorySlot.salt,
                            maximumSequence: slot.maximumSequence, trackHighWater: false,
                            accepting: { slot.publishers(in: $0) != nil }) else { return ([], 0) }
                        // Read all valid replicas, rather than letting one writer's highest sequence hide every other pointer.
                        return (Array(Set(result.records.flatMap { slot.publishers(in: $0) ?? [] })), result.responders)
                    }
                }
            }
            var results: [([Data], Int)] = []
            for await result in group { results.append(result) }
            return results
        }
        try Task.checkCancellation()
        let responders = results.reduce(0) { $0 + $1.1 }
        guard responders > 0 else { throw PeerError.unavailable("No public rendezvous slots responded") }
        return .init(keys: Array(Set(results.flatMap(\.0))), responders: responders, failedSlots: results.filter { $0.1 == 0 }.count)
    }

    public func servePublicRecords(_ records: [Data: MutableRecord]) async throws {
        if !records.isEmpty { try Task.checkCancellation() }
        let transport = try datagramSocket()
        let responder = PublicPeerResponder(nodeID: nodeID, records: records)
        if records.isEmpty { await transport.setHandler(nil) }
        else {
            await transport.setHandler { method, args, endpoint in
                responder.respond(method: method, args: args, endpoint: endpoint)
            }
        }
    }

    public func requestPublicRecord(endpoint: DHTEndpoint, topic: Data) async throws -> MutableRecord {
        guard Self.parsePeer(Self.compact(endpoint), allowLocal: allowLocal) != nil else { throw PeerError.invalid("Non-public peer endpoint") }
        let hello = try await rpc("upovi_hello", args: ["id": .bytes(nodeID), "topic": .bytes(topic)], endpoint: endpoint)
        guard let token = hello["token"]?.data, token.count == 16 else { throw PeerError.invalid("Invalid peer challenge") }
        let response = try await rpc("upovi_report", args: ["id": .bytes(nodeID), "topic": .bytes(topic), "token": .bytes(token)], endpoint: endpoint)
        guard let record = Self.record(response, salt: topic), record.isValid else { throw PeerError.invalid("Invalid peer report signature") }
        return record
    }

    private func rpc(_ method: String, args: [String: BValue], endpoint: DHTEndpoint) async throws -> [String: BValue] {
        try Task.checkCancellation()
        let transaction = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let packet = BValue.dict(["t": .bytes(transaction), "y": .string("q"), "q": .string(method), "a": .dict(args), "ro": .int(1)]).encoded()
        let data = try await datagramSocket().query(packet, transaction: transaction, endpoint: endpoint)
        guard let response = try BValue.decode(data, strict: false).dictionary, response["t"]?.data == transaction else { throw PeerError.invalid("DHT transaction mismatch") }
        guard response["y"]?.string == "r", let body = response["r"]?.dictionary else { throw PeerError.unavailable("DHT rejected \(method)") }
        return body
    }

    private static func record(_ response: [String: BValue], salt: Data) -> MutableRecord? {
        guard let key = response["k"]?.data, let seq = response["seq"]?.integer, let signature = response["sig"]?.data, let value = response["v"] else { return nil }
        return .init(publicKey: key, salt: salt, sequence: seq, value: value, signature: signature)
    }

    private static func closer(_ a: Data, _ b: Data, target: Data) -> Bool {
        let a = Array(a), b = Array(b), target = Array(target)
        for i in 0..<20 { let x = a[i] ^ target[i], y = b[i] ^ target[i]; if x != y { return x < y } }
        return false
    }

    public static func parsePeer(_ data: Data, allowLocal: Bool = false) -> DHTEndpoint? {
        let ip = Array(data)
        guard ip.count == 6 else { return nil }
        let port = UInt16(ip[4]) << 8 | UInt16(ip[5])
        let nonPublic = ip[0] == 0 || ip[0] == 10 || ip[0] == 127 || ip[0] >= 224 ||
            (ip[0] == 169 && ip[1] == 254) || (ip[0] == 172 && (16...31).contains(ip[1])) ||
            (ip[0] == 192 && ip[1] == 168) || (ip[0] == 100 && (64...127).contains(ip[1])) ||
            (ip[0] == 198 && (ip[1] == 18 || ip[1] == 19))
        guard port > 0, allowLocal || !nonPublic else { return nil }
        return .init(host: ip.prefix(4).map(String.init).joined(separator: "."), port: port)
    }

    private static func compact(_ endpoint: DHTEndpoint) -> Data {
        let octets = endpoint.host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return Data() }
        return Data(octets + [UInt8(endpoint.port >> 8), UInt8(endpoint.port & 255)])
    }

    public static func parseNodes(_ data: Data, allowLocal: Bool = false) -> [DHTNode] {
        let bytes = Array(data)
        guard bytes.count.isMultiple(of: 26) else { return [] }
        return stride(from: 0, to: bytes.count, by: 26).compactMap { offset in
            guard let endpoint = parsePeer(Data(bytes[(offset + 20)..<(offset + 26)]), allowLocal: allowLocal) else { return nil }
            return .init(id: Data(bytes[offset..<(offset + 20)]), endpoint: endpoint)
        }
    }
}
