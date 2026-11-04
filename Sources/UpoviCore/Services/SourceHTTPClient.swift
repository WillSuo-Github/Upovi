import Foundation
import Darwin

/// Bounded metadata cache only. Downloads and installation proofs have separate lifetimes.
public actor SourceHTTPClient {
    public static let shared = SourceHTTPClient()
    private struct Entry {
        let response: HTTPMetadataResponse
        let validatedAt: Date
        let generation: UInt64
    }
    private struct Cooldown: Codable { let error: HTTPStatusError; let until: Date }
    private var entries: [URL: Entry] = [:]
    private var originsInUse: Set<String> = []
    private var cooldowns: [String: Cooldown] = [:]
    private var generation: UInt64 = 0
    private let transport: @Sendable (URL, Int, [String: String]) async throws -> HTTPMetadataResponse
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let byteLimit: Int
    private let entryLimit: Int
    private let cooldownURL: URL?

    public init() {
        transport = { try await HTTPTransfer.metadata(from: $0, limit: $1, headers: $2) }
        now = { @Sendable in Date() }; sleep = { @Sendable duration in try await Task.sleep(for: duration) }
        byteLimit = 64_000_000; entryLimit = 128
        cooldownURL = URL.cachesDirectory.appending(path: "Upovi/SourceMetadata/github-cooldown.json")
        cooldowns = Self.restoreCooldown(cooldownURL, now: Date())
    }
    init(byteLimit: Int = 64_000_000, entryLimit: Int = 128, cooldownURL: URL? = nil,
         now: @escaping @Sendable () -> Date = { @Sendable in Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { @Sendable duration in try await Task.sleep(for: duration) },
         transport: @escaping @Sendable (URL, Int, [String: String]) async throws -> HTTPMetadataResponse) {
        self.transport = transport; self.now = now; self.sleep = sleep
        self.byteLimit = byteLimit; self.entryLimit = entryLimit; self.cooldownURL = cooldownURL
        cooldowns = Self.restoreCooldown(cooldownURL, now: now())
    }

    /// Manual refresh bypasses freshness, but retains validators and server-directed cooldowns.
    public func revalidate() { generation &+= 1; UpoviLog.network.info("event=metadata.revalidate generation=\(generation)") }

    public func data(from url: URL, limit: Int) async throws -> Data {
        let operation = UpoviLogOperation("metadata.request", category: .network, details: UpoviDiagnosticContext.source(url) + " limit=\(limit)")
        return try await UpoviDiagnosticContext.$operationID.withValue(operation.id) {
            do {
                let data = try await loadData(from: url, limit: limit)
                operation.finish(details: "bytes=\(data.count)")
                return data
            } catch { operation.fail(error); throw error }
        }
    }
    private func loadData(from url: URL, limit: Int) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host, limit > 0 else {
            throw URLError(.unsupportedURL)
        }
        let origin = host.lowercased() + ":" + String(url.port ?? 443)
        // Serial requests per origin also prevent GitHub release checks from bursting in parallel.
        while originsInUse.contains(origin) {
            try Task.checkCancellation(); try await sleep(.milliseconds(50))
        }
        try Task.checkCancellation()
        originsInUse.insert(origin); defer { originsInUse.remove(origin) }
        let clock = now()
        cooldowns = cooldowns.filter { $0.value.until > clock }
        if let entry = entries[url], entry.generation == generation,
           clock >= entry.validatedAt,
           clock.timeIntervalSince(entry.validatedAt) < Self.freshness(entry.response.headers) {
            guard entry.response.data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            UpoviLog.network.info("event=metadata.cacheHit generation=\(generation) bytes=\(entry.response.data.count)")
            return entry.response.data
        }
        if let value = cooldowns[origin] ?? cooldowns[url.absoluteString] { UpoviLog.network.warning("event=metadata.cooldown until=\(value.until.ISO8601Format()) \(UpoviDiagnosticContext.errorSummary(value.error))"); throw value.error }
        let requestGeneration = generation
        let previous = entries[url]
        var headers: [String: String] = ["Cache-Control": "no-cache"]
        if let etag = Self.validator(previous?.response.headers["etag"]) { headers["If-None-Match"] = etag }
        else if let date = Self.validator(previous?.response.headers["last-modified"]) { headers["If-Modified-Since"] = date }
        if host.lowercased() == "api.github.com" { headers["Accept"] = "application/vnd.github+json" }
        for attempt in 0..<3 {
            do {
                UpoviLog.network.info("event=metadata.attempt attempt=\(attempt + 1) conditional=\(headers["If-None-Match"] != nil || headers["If-Modified-Since"] != nil)")
                let response = try await transport(url, limit, headers)
                UpoviLog.network.info("event=metadata.response status=\(response.status) bytes=\(response.data.count)")
                try Task.checkCancellation()
                let effective: HTTPMetadataResponse
                if response.status == 304 {
                    guard !headers.keys.filter({ $0.hasPrefix("If-") }).isEmpty, let previous else { throw URLError(.badServerResponse) }
                    var combined = previous.response.headers
                    combined.merge(response.headers) { _, new in new }
                    effective = .init(data: previous.response.data, status: 200, headers: combined)
                } else {
                    guard response.status == 200 else { throw HTTPStatusError(statusCode: response.status) }
                    effective = response
                }
                guard effective.data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
                let control = effective.headers["cache-control"]?.lowercased() ?? ""
                if control.contains("no-store") || effective.headers["vary"]?.contains("*") == true {
                    entries[url] = nil
                } else if effective.data.count <= byteLimit {
                    entries[url] = .init(response: effective, validatedAt: now(), generation: requestGeneration)
                    prune()
                } else { entries[url] = nil }
                if host.lowercased() == "api.github.com", effective.headers["x-ratelimit-remaining"] == "0" {
                    let reset = effective.headers["x-ratelimit-reset"].flatMap(Double.init).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                    let until = min(max(reset ?? now().addingTimeInterval(60), now().addingTimeInterval(1)), now().addingTimeInterval(86400))
                    setCooldown(origin, error: .init(statusCode: 403, retryAt: until, rateLimited: true), until: until)
                }
                return effective.data
            } catch {
                try Task.checkCancellation()
                if let http = error as? HTTPStatusError {
                    // Only explicit throttling evidence is called rate limiting. Plain 403 is denied.
                    if http.rateLimited || http.retryAt != nil {
                        let until = max(http.retryAt ?? now().addingTimeInterval(60), now().addingTimeInterval(1))
                        setCooldown(origin, error: http, until: until)
                        throw error
                    }
                    if [401, 403, 404].contains(http.statusCode) {
                        setCooldown(url.absoluteString, error: http, until: now().addingTimeInterval(60))
                        throw error
                    }
                }
                guard attempt < 2, Self.transient(error) else { throw error }
                UpoviLog.network.warning("event=metadata.retry attempt=\(attempt + 1) \(UpoviDiagnosticContext.errorSummary(error))")
                try await sleep(.seconds(attempt + 1))
            }
        }
        throw URLError(.badServerResponse)
    }

    private static func validator(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private static func freshness(_ headers: [String: String]) -> TimeInterval {
        let control = headers["cache-control"]?.lowercased() ?? ""
        if control.contains("no-cache") { return 0 }
        for directive in control.split(separator: ",") {
            let pieces = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pieces.count == 2, pieces[0] == "max-age", let age = Double(pieces[1].replacingOccurrences(of: "\"", with: "")), age.isFinite {
                return min(max(age, 0), 300)
            }
        }
        return 300
    }
    private func setCooldown(_ key: String, error: HTTPStatusError, until: Date) {
        if cooldowns[key] == nil, cooldowns.count >= 128,
           let oldest = cooldowns.min(by: { $0.value.until < $1.value.until })?.key { cooldowns[oldest] = nil }
        cooldowns[key] = .init(error: error, until: until)
        if key == "api.github.com:443" { persistCooldown() }
    }
    private static func restoreCooldown(_ file: URL?, now: Date) -> [String: Cooldown] {
        guard let file, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 4096,
              let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Cooldown.self, from: data),
              stored.error.rateLimited, stored.until > now, stored.until <= now.addingTimeInterval(86400) else { return [:] }
        return ["api.github.com:443": stored]
    }
    private func persistCooldown() {
        guard let file = cooldownURL, let value = cooldowns["api.github.com:443"],
              let data = try? JSONEncoder().encode(value) else { return }
        let parent = file.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path else { return }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return }
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { UpoviLog.storage.warning("event=metadata.cooldownSaveFailed \(UpoviDiagnosticContext.errorSummary(error))") }
    }

    private static func transient(_ error: any Error) -> Bool {
        if let http = error as? HTTPStatusError { return [408, 500, 502, 503, 504].contains(http.statusCode) }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(value.code)
    }
    private func prune() {
        var bytes = entries.values.reduce(0) { $0 + $1.response.data.count }
        for (url, entry) in entries.sorted(by: { $0.value.validatedAt < $1.value.validatedAt }) {
            guard entries.count > entryLimit || bytes > byteLimit else { break }
            entries[url] = nil; bytes -= entry.response.data.count
        }
    }
}
