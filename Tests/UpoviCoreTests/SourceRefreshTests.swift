import Foundation
import XCTest
@testable import UpoviCore

final class SourceRefreshTests: XCTestCase, @unchecked Sendable {
    func testCatalogRefreshReplacesCachedVersionAndDoesNotHideRefreshFailure() async throws {
        let source = CatalogSource()
        let catalog = CaskCatalog(fetch: { try await source.fetch() })
        let old = try await catalog.metadata(for: "app.synthetic.source")
        let cached = try await catalog.metadata(for: "app.synthetic.source")
        XCTAssertEqual(old?.version, "1"); XCTAssertEqual(cached?.version, "1")
        await catalog.invalidate()
        let new = try await catalog.metadata(for: "app.synthetic.source")
        XCTAssertEqual(new?.version, "2")
        await catalog.invalidate()
        do { _ = try await catalog.metadata(for: "app.synthetic.source"); XCTFail("Must not reuse stale success") } catch { }
        let calls = await source.calls; XCTAssertEqual(calls, 3)
    }
    func testInvalidationDiscardsAnOlderInflightCatalogResponse() async throws {
        let source = CatalogRace()
        let catalog = CaskCatalog(fetch: { await source.fetch() })
        let old = Task { try await catalog.metadata(for: "app.synthetic.source") }
        await source.waitForEntry()
        await catalog.invalidate()
        let current = try await catalog.metadata(for: "app.synthetic.source")
        XCTAssertEqual(current?.version, "2")
        await source.release()
        let previousWaiter = try await old.value
        XCTAssertEqual(previousWaiter?.version, "2")
    }
    func testManualEntriesMatchExactIdentitiesAndNeverInventCandidates() async {
        for (bundle, host) in [("dev.appbinnacle.AppBinnacle", "github.com"), ("com.ws.youtube-music", "apps.apple.com")] {
            let app = InstalledApp(name: "Renamed", bundleID: bundle, version: "1", path: "/synthetic/fixture.app")
            let result = await UpdateChecker.check(app, fetch: { _, _ in XCTFail("No automatic source assigned"); return Data() }, catalog: { _ in XCTFail("No guessed catalog"); return nil })
            XCTAssertEqual(result.manualURL?.host, host); XCTAssertEqual(result.status, .unsupported); XCTAssertTrue(result.candidates.isEmpty)
        }
        XCTAssertNil(ManualUpdateSource.forBundle("com.ws.youtube-music.unrelated"))
        XCTAssertNil(ManualUpdateSource.forBundle("dev.unrelated.AppBinnacle"))
    }
    func testTransportCarriesConditionalHeadersAndAccepts304OnlyForMetadata() async throws {
        let url = URL(string: "https://\(UUID().uuidString).upovi.invalid/feed")!
        MetadataWire.state.set(url, code: 304, headers: ["ETag": "\"v1\""])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MetadataWire.self]
        let response = try await HTTPTransfer.metadata(from: url, limit: 100, headers: ["If-None-Match": "\"v1\""], configuration: config)
        XCTAssertEqual(response.status, 304); XCTAssertEqual(response.headers["etag"], "\"v1\"")
        XCTAssertEqual(MetadataWire.state.request(url)?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        let denied = URL(string: "https://\(UUID().uuidString).upovi.invalid/feed")!
        MetadataWire.state.set(denied, code: 429, headers: ["Retry-After": "120"])
        do { _ = try await HTTPTransfer.metadata(from: denied, limit: 100, headers: [:], configuration: config); XCTFail("Expected throttling") }
        catch {
            let issue = try XCTUnwrap(error as? HTTPStatusError)
            XCTAssertTrue(issue.rateLimited); XCTAssertNotNil(issue.retryAt)
        }
    }
}

private actor CatalogSource {
    var calls = 0
    func fetch() throws -> Data {
        calls += 1
        if calls >= 3 { throw URLError(.notConnectedToInternet) }
        return Data("[{\"token\":\"fixture\",\"version\":\"\(calls)\",\"artifacts\":[{\"uninstall\":[{\"quit\":\"app.synthetic.source\"}]}]}]".utf8)
    }
}
private final class MetadataWireState: @unchecked Sendable {
    let lock = NSLock()
    var replies: [URL: (Int, [String: String])] = [:]
    var requests: [URL: URLRequest] = [:]
    func set(_ url: URL, code: Int, headers: [String: String]) { lock.withLock { replies[url] = (code, headers) } }
    func request(_ url: URL) -> URLRequest? { lock.withLock { requests[url] } }
    func receive(_ request: URLRequest) -> (Int, [String: String]) {
        lock.withLock { requests[request.url!] = request; return replies[request.url!] ?? (500, [:]) }
    }
}
private final class MetadataWire: URLProtocol, @unchecked Sendable {
    static let state = MetadataWireState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".upovi.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers) = Self.state.receive(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor CatalogRace {
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func fetch() async -> Data {
        calls += 1; let version = calls
        if version == 1 { await withCheckedContinuation { gate = $0; observer?.resume(); observer = nil } }
        return Data("[{\"token\":\"fixture\",\"version\":\"\(version)\",\"artifacts\":[{\"uninstall\":[{\"quit\":\"app.synthetic.source\"}]}]}]".utf8)
    }
    func waitForEntry() async { if gate != nil { return }; await withCheckedContinuation { observer = $0 } }
    func release() { gate?.resume(); gate = nil }
}
