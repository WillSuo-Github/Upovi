import Foundation
import Darwin

/// One IPv4 UDP port for routing, announcements, and peer requests. Queue-confined state.
final class DHTSocket: @unchecked Sendable {
    typealias Handler = @Sendable (String, [String: BValue], DHTEndpoint) -> [String: BValue]?
    private struct Pending {
        let endpoint: DHTEndpoint
        let continuation: CheckedContinuation<Data, any Error>
    }
    private let queue = DispatchQueue(label: "app.upovi.dht.socket")
    private let descriptor: Int32
    private var source: DispatchSourceRead?
    private var pending: [Data: Pending] = [:]
    private var cancelled = Set<Data>()
    private var handler: Handler?
    private var inboundWindow = Date()
    private var inboundCounts: [String: Int] = [:]
    private var inboundTotal = 0
    let port: UInt16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PeerError.unavailable("Cannot create UDP socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw PeerError.unavailable("Cannot bind UDP socket") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        descriptor = fd
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = readSource
        readSource.setEventHandler { [weak self] in self?.receive() }
        readSource.setCancelHandler { Darwin.close(fd) }
        readSource.resume()
    }

    deinit { source?.cancel() }

    func setHandler(_ handler: Handler?) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in self.handler = handler; continuation.resume() }
        }
    }

    func query(_ packet: Data, transaction: Data, endpoint: DHTEndpoint, timeout: TimeInterval = 3) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if cancelled.remove(transaction) != nil { continuation.resume(throwing: CancellationError()); return }
                    guard pending.count < 64, let resolved = Self.resolve(endpoint) else {
                        continuation.resume(throwing: PeerError.unavailable("Cannot resolve DHT endpoint")); return
                    }
                    pending[transaction] = Pending(endpoint: resolved, continuation: continuation)
                    if !send(packet, to: resolved) {
                        finish(transaction, .failure(PeerError.unavailable("Cannot send UDP packet"))); return
                    }
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(transaction, .failure(PeerError.unavailable("UDP endpoint timed out")))
                    }
                }
            }
        } onCancel: {
            self.queue.async { [self] in
                if pending[transaction] != nil { finish(transaction, .failure(CancellationError())) }
                else { if cancelled.count > 128 { cancelled.removeAll() }; cancelled.insert(transaction) }
            }
        }
    }

    private func finish(_ transaction: Data, _ result: Result<Data, any Error>) {
        pending.removeValue(forKey: transaction)?.continuation.resume(with: result)
    }

    private func receive() {
        for _ in 0..<64 {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var address = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &size) }
            }
            guard count > 0 else { return }
            var ip = address.sin_addr
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &host, socklen_t(host.count)) != nil else { continue }
            let remote = DHTEndpoint(host: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), port: UInt16(bigEndian: address.sin_port))
            let data = Data(buffer.prefix(count))
            guard let packet = try? BValue.decode(data, strict: false).dictionary, let transaction = packet["t"]?.data else { continue }
            if let request = pending[transaction], request.endpoint == remote, ["r", "e"].contains(packet["y"]?.string ?? "") {
                finish(transaction, .success(data))
            } else if count <= 1400, transaction.count <= 16, packet["y"]?.string == "q", allowIncoming(remote),
                      let method = packet["q"]?.string, let args = packet["a"]?.dictionary,
                      let body = handler?(method, args, remote) {
                let response = BValue.dict(["t": .bytes(transaction), "y": .string("r"), "r": .dict(body)]).encoded()
                if response.count <= 1400 { _ = send(response, to: remote) }
            }
        }
    }

    private func allowIncoming(_ endpoint: DHTEndpoint) -> Bool {
        if Date().timeIntervalSince(inboundWindow) >= 60 {
            inboundWindow = Date(); inboundCounts = [:]; inboundTotal = 0
        }
        guard inboundTotal < 1024, inboundCounts[endpoint.host, default: 0] < 128 else { return false }
        inboundTotal += 1; inboundCounts[endpoint.host, default: 0] += 1
        return true
    }

    private func send(_ data: Data, to endpoint: DHTEndpoint) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else { return false }
        let count = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return count == data.count
    }

    private static func resolve(_ endpoint: DHTEndpoint) -> DHTEndpoint? {
        var hints = addrinfo()
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }
        guard let raw = result.pointee.ai_addr else { return nil }
        var ip = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ip, &host, socklen_t(host.count)) != nil else { return nil }
        return .init(host: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), port: endpoint.port)
    }
}
