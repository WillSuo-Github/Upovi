import CryptoKit
import XCTest
@testable import UpoviCore

final class ResumableDownloadTests: XCTestCase, @unchecked Sendable {
    private let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.resume", version: "1", path: "/synthetic/F.app", teamID: "SYNTHETIC1")
    private func setup(_ replies: [ResumeReply], expected: String = ResumeReply.golden) throws -> (URL, URL, DownloadDescriptor, URLSessionConfiguration) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).upovi.invalid/update.zip")!
        ResumeRegistry.shared.set(replies, for: url)
        let sha = SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResumeProtocol.self]
        return (root, url, .init(url: url, sha256: sha), config)
    }
    private func interrupt(_ cache: ArtifactDownloadCache, descriptor: DownloadDescriptor, to output: URL,
                           whileHeld: @Sendable () async throws -> Void = { }) async throws {
        let gate = DownloadGate(), app = app
        let task = Task {
            do {
                try await cache.download(descriptor, app: app, to: output) { bytes, _ in
                    if bytes > 0 { Task { await gate.signal() } }
                }
            } catch { await gate.fail(error); throw error }
        }
        let timeout = Task { do { try await Task.sleep(for: .seconds(5)); await gate.fail() } catch { } }
        defer { timeout.cancel() }
        do { try await gate.wait(); try await whileHeld() } catch { task.cancel(); _ = try? await task.value; throw error }
        task.cancel()
        do { try await task.value; XCTFail("Interrupted download must not finish") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testCancelledDownloadResumesAfterRecreatingCacheAndUsesIfRange() async throws {
        let (root, url, descriptor, config) = try setup([.prefix(), .suffix()])
        let directory = root.appending(path: "Cache")
        try await interrupt(ArtifactDownloadCache(directory: directory, configuration: config), descriptor: descriptor, to: root.appending(path: "first"))
        let cache = ArtifactDownloadCache(directory: directory, configuration: config)
        let output = root.appending(path: "final")
        try await cache.download(descriptor, app: app, to: output) { _, _ in }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), ResumeReply.golden)
        let requests = ResumeRegistry.shared.requests(for: url)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=262144-")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
    }
    func testIgnoredRangeRestartsAtZeroInsteadOfAppendingChangedContent() async throws {
        let (root, url, descriptor, config) = try setup([.prefix(), .full("ABCDEFGHIJ", etag: "\"v2\"")], expected: "ABCDEFGHIJ")
        let cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
        try await interrupt(cache, descriptor: descriptor, to: root.appending(path: "first"))
        let output = root.appending(path: "final")
        try await cache.download(descriptor, app: app, to: output) { _, _ in }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "ABCDEFGHIJ")
        XCTAssertEqual(ResumeRegistry.shared.requests(for: url)[1].value(forHTTPHeaderField: "Range"), "bytes=262144-")
    }
    func testInvalidPartialResponsesRetryOnceWithAFullRequest() async throws {
        for bad in [ResumeReply(status: 416, headers: [:], body: Data()),
                    .suffix(etag: "\"different\""), .suffix(range: "bytes 3-8/10"), .suffix(range: "bytes 4/9-10")] {
            let (root, url, descriptor, config) = try setup([.prefix(), bad, .full(ResumeReply.golden)])
            let cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
            try await interrupt(cache, descriptor: descriptor, to: root.appending(path: "first"))
            let output = root.appending(path: "final")
            try await cache.download(descriptor, app: app, to: output) { _, _ in }
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), ResumeReply.golden)
            let requests = ResumeRegistry.shared.requests(for: url)
            XCTAssertEqual(requests.count, 3)
            XCTAssertNil(requests[2].value(forHTTPHeaderField: "Range"))
        }
    }
    func testWeakValidatorsAreNeverUsedToAppendAPrefix() async throws {
        for value in ["W/\"v1\"", "\"v1\"\r\n", "\"v1\"\n"] { XCTAssertFalse(DownloadResumeState.validETag(value)) }
        let (root, url, descriptor, config) = try setup([.prefix(etag: "W/\"v1\""), .full(ResumeReply.golden)])
        let cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
        try await interrupt(cache, descriptor: descriptor, to: root.appending(path: "first"))
        try await cache.download(descriptor, app: app, to: root.appending(path: "final")) { _, _ in }
        XCTAssertNil(ResumeRegistry.shared.requests(for: url)[1].value(forHTTPHeaderField: "Range"))
    }
    func testChangedIntegrityProofDoesNotReuseAnotherTargetsPartial() async throws {
        let (root, url, old, config) = try setup([.prefix(), .full("ABCDEFGHIJ")])
        let cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
        try await interrupt(cache, descriptor: old, to: root.appending(path: "first"))
        let sha = SHA256.hash(data: Data("ABCDEFGHIJ".utf8)).map { String(format: "%02x", $0) }.joined()
        let updated = DownloadDescriptor(url: url, sha256: sha)
        try await cache.download(updated, app: app, to: root.appending(path: "final")) { _, _ in }
        XCTAssertNil(ResumeRegistry.shared.requests(for: url)[1].value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try String(contentsOf: root.appending(path: "final"), encoding: .utf8), "ABCDEFGHIJ")
    }
    func testSeparateCacheInstancesCannotWriteAnActivePartialTogether() async throws {
        let (root, url, descriptor, config) = try setup([.prefix(), .suffix()])
        let directory = root.appending(path: "Cache"), first = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
        let second = ArtifactDownloadCache(directory: directory, configuration: config), app = app
        try await interrupt(first, descriptor: descriptor, to: root.appending(path: "first"), whileHeld: {
            do {
                try await second.download(descriptor, app: app, to: root.appending(path: "collision")) { _, _ in }
                XCTFail("An active partial must remain locked")
            } catch { }
            XCTAssertEqual(ResumeRegistry.shared.requests(for: url).count, 1)
        })
        try await second.download(descriptor, app: app, to: root.appending(path: "final")) { _, _ in }
        XCTAssertEqual(ResumeRegistry.shared.requests(for: url).count, 2)
    }
    func testRetentionPrunesOnlyInactiveKnownCacheEntries() async throws {
        let (root, _, _, config) = try setup([])
        let directory = root.appending(path: "Cache"), old = directory.appending(path: String(repeating: "f", count: 64))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appending(path: "Complete.bin"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
        let unrelated = directory.appending(path: "keep.txt"); try Data("keep".utf8).write(to: unrelated)
        try await ArtifactDownloadCache(directory: directory, configuration: config).prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    }
    func testCachedArtifactsAreReverifiedAndTamperingTriggersFreshDownload() async throws {
        let (root, url, descriptor, config) = try setup([.full(ResumeReply.golden), .full(ResumeReply.golden)])
        let directory = root.appending(path: "Cache"), cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
        try await cache.download(descriptor, app: app, to: root.appending(path: "first")) { _, _ in }
        try await cache.download(descriptor, app: app, to: root.appending(path: "second")) { _, _ in }
        XCTAssertEqual(ResumeRegistry.shared.requests(for: url).count, 1)
        try Data("tampered".utf8).write(to: directory.appending(path: ArtifactDownloadCache.key(descriptor) + "/Complete.bin"))
        try await cache.download(descriptor, app: app, to: root.appending(path: "third")) { _, _ in }
        XCTAssertEqual(ResumeRegistry.shared.requests(for: url).count, 2)
        XCTAssertEqual(try String(contentsOf: root.appending(path: "third"), encoding: .utf8), ResumeReply.golden)
    }
    func testWrongFinalProofNeverProducesAnInstallableArtifact() async throws {
        let (root, _, descriptor, config) = try setup([.full("WRONG!!!!!")])
        let cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: config)
        let output = root.appending(path: "final")
        do { try await cache.download(descriptor, app: app, to: output) { _, _ in }; XCTFail("Checksum must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testLinkedPartialCannotOverwriteAnUnrelatedFile() async throws {
        let (root, _, descriptor, config) = try setup([])
        let directory = root.appending(path: "Cache"), entry = directory.appending(path: ArtifactDownloadCache.key(descriptor))
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let external = root.appending(path: "untouched"); try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: entry.appending(path: "Download.part"), withDestinationURL: external)
        do {
            try await ArtifactDownloadCache(directory: directory, configuration: config).download(descriptor, app: app, to: root.appending(path: "final")) { _, _ in }
            XCTFail("Linked partial must be rejected")
        } catch { }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "keep")
    }
}

private actor DownloadGate {
    private var outcome: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    func signal() { outcome = .success(()); waiter?.resume(); waiter = nil }
    func fail(_ error: any Error = URLError(.timedOut)) { outcome = .failure(error); waiter?.resume(throwing: error); waiter = nil }
    func wait() async throws { if let outcome { return try outcome.get() }; try await withCheckedThrowingContinuation { waiter = $0 } }
}
private struct ResumeReply: Sendable {
    static let golden = String(repeating: "a", count: 262_144) + "efghij"
    let status: Int
    let headers: [String: String]
    let body: Data
    var finish = true
    static func prefix(etag: String = "\"v1\"") -> Self { .init(status: 200, headers: ["ETag": etag, "Content-Length": "262150"], body: Data(repeating: 97, count: 262_144), finish: false) }
    static func suffix(etag: String = "\"v1\"", range: String = "bytes 262144-262149/262150") -> Self { .init(status: 206, headers: ["ETag": etag, "Content-Length": "6", "Content-Range": range], body: Data("efghij".utf8)) }
    static func full(_ value: String, etag: String = "\"v1\"") -> Self { .init(status: 200, headers: ["ETag": etag, "Content-Length": String(value.utf8.count)], body: Data(value.utf8)) }
}
private final class ResumeRegistry: @unchecked Sendable {
    static let shared = ResumeRegistry()
    private let lock = NSLock()
    private var replies: [URL: [ResumeReply]] = [:]
    private var observed: [URL: [URLRequest]] = [:]
    func set(_ values: [ResumeReply], for url: URL) { lock.withLock { replies[url] = values; observed[url] = [] } }
    func take(_ request: URLRequest) -> ResumeReply? {
        lock.withLock {
            guard let url = request.url else { return nil }
            observed[url, default: []].append(request)
            guard replies[url]?.isEmpty == false else { return nil }
            return replies[url]?.removeFirst()
        }
    }
    func requests(for url: URL) -> [URLRequest] { lock.withLock { observed[url] ?? [] } }
}
private final class ResumeProtocol: URLProtocol, @unchecked Sendable {
    private let stoppedLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".upovi.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = ResumeRegistry.shared.take(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        DispatchQueue.global().async { [self] in
            guard !stoppedLock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                guard !stoppedLock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didLoad: reply.body)
                if reply.finish { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }
    override func stopLoading() { stoppedLock.withLock { stopped = true } }
}
