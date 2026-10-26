import Foundation
import XCTest
@testable import UpoviCore

final class SourceHTTPClientTests: XCTestCase, @unchecked Sendable {
    private let url = URL(string: "https://api.github.com/repos/synthetic/app/releases/latest")!
    func testManualRevalidationUsesValidatorAndNeverReportsStaleDataOnFailure() async throws {
        let replies = MetadataReplies([
            .success(.init(data: Data("old".utf8), status: 200, headers: ["etag": "\"1\""])),
            .success(.init(data: Data(), status: 304, headers: [:])),
            .failure(HTTPStatusError(statusCode: 403))
        ])
        let client = SourceHTTPClient(transport: { try await replies.next($0, $1, $2) })
        let first = try await client.data(from: url, limit: 100)
        let cached = try await client.data(from: url, limit: 100)
        XCTAssertEqual(first, cached)
        await client.revalidate()
        let unchanged = try await client.data(from: url, limit: 100)
        XCTAssertEqual(unchanged, first)
        let headers = await replies.requests
        XCTAssertEqual(headers.count, 2); XCTAssertEqual(headers[1]["If-None-Match"], "\"1\"")
        await client.revalidate()
        do { _ = try await client.data(from: url, limit: 100); XCTFail("Stale result must not hide failure") }
        catch { XCTAssertEqual((error as? HTTPStatusError)?.statusCode, 403) }
    }
    func testRateLimitBlocksSameOriginEvenAfterRefreshAndDoesNotBlockOtherHosts() async throws {
        let replies = MetadataReplies([.failure(HTTPStatusError(statusCode: 429, retryAt: Date().addingTimeInterval(300), rateLimited: true)),
                                       .success(.init(data: Data("other".utf8), status: 200, headers: [:]))])
        let client = SourceHTTPClient(transport: { try await replies.next($0, $1, $2) })
        for target in [url, URL(string: "https://api.github.com/repos/synthetic/other/releases/latest")!] {
            await client.revalidate()
            do { _ = try await client.data(from: target, limit: 100); XCTFail("Expected cooldown") }
            catch { XCTAssertTrue((error as? HTTPStatusError)?.rateLimited == true) }
        }
        _ = try await client.data(from: URL(string: "https://other.invalid/feed")!, limit: 100)
        let count = await replies.requests.count; XCTAssertEqual(count, 2)
    }
    func testPlainForbiddenIsNotInventedAsRateLimitAndOnlyCoolsThatURL() async throws {
        let replies = MetadataReplies([.failure(HTTPStatusError(statusCode: 403)), .success(.init(data: Data(), status: 200, headers: [:]))])
        let client = SourceHTTPClient(transport: { try await replies.next($0, $1, $2) })
        for _ in 0..<2 {
            do { _ = try await client.data(from: url, limit: 100); XCTFail("Expected denied") }
            catch { XCTAssertFalse((error as? HTTPStatusError)?.rateLimited ?? true) }
        }
        _ = try await client.data(from: URL(string: "https://api.github.com/repos/synthetic/other/releases/latest")!, limit: 100)
        let count = await replies.requests.count; XCTAssertEqual(count, 2)
    }
    func testTransientFailuresAreBoundedAndTLSIsNeverRetried() async throws {
        let transient = MetadataReplies(Array(repeating: .failure(HTTPStatusError(statusCode: 503)), count: 3))
        let client = SourceHTTPClient(sleep: { _ in }, transport: { try await transient.next($0, $1, $2) })
        do { _ = try await client.data(from: url, limit: 100); XCTFail("Expected failure") } catch { }
        let count = await transient.requests.count; XCTAssertEqual(count, 3)
        let tls = MetadataReplies([.failure(URLError(.serverCertificateUntrusted))])
        let secure = SourceHTTPClient(sleep: { _ in }, transport: { try await tls.next($0, $1, $2) })
        do { _ = try await secure.data(from: url, limit: 100); XCTFail("Expected TLS failure") } catch { }
        let tlsCount = await tls.requests.count; XCTAssertEqual(tlsCount, 1)
    }
    func testNoStoreNoCacheUnsolicited304AndCacheLimits() async throws {
        let value = HTTPMetadataResponse(data: Data("abcd".utf8), status: 200, headers: ["etag": "\"v1\"", "cache-control": "no-store"])
        let replies = MetadataReplies([.success(value), .success(value)])
        let client = SourceHTTPClient(transport: { try await replies.next($0, $1, $2) })
        for _ in 0..<2 { _ = try await client.data(from: url, limit: 100) }
        let requests = await replies.requests; XCTAssertEqual(requests.count, 2); XCTAssertNil(requests[1]["If-None-Match"])
        let noCache = MetadataReplies([.success(.init(data: Data("abcd".utf8), status: 200, headers: ["cache-control": "no-cache"])),
                                      .success(.init(data: Data("new".utf8), status: 200, headers: [:]))])
        let fresh = SourceHTTPClient(transport: { try await noCache.next($0, $1, $2) })
        _ = try await fresh.data(from: url, limit: 100)
        let updated = try await fresh.data(from: url, limit: 100); XCTAssertEqual(updated, Data("new".utf8))
        do { _ = try await fresh.data(from: url, limit: 1); XCTFail("Cached data must obey caller limit") } catch { }
        let invalid = SourceHTTPClient(transport: { _, _, _ in .init(data: Data(), status: 304, headers: [:]) })
        do { _ = try await invalid.data(from: url, limit: 100); XCTFail("An unsolicited 304 is not a valid body") } catch { }
        let limitedReplies = MetadataReplies(Array(repeating: .success(.init(data: Data("abcd".utf8), status: 200, headers: [:])), count: 3))
        let limited = SourceHTTPClient(byteLimit: 4, entryLimit: 1, transport: { try await limitedReplies.next($0, $1, $2) })
        for target in [url, URL(string: "https://other.invalid/feed")!, url] { _ = try await limited.data(from: target, limit: 100) }
        let boundedCount = await limitedReplies.requests.count; XCTAssertEqual(boundedCount, 3)
    }
    func testRateLimitHeaderParsingAndDiagnosticAllowlist() throws {
        let clock = Date(timeIntervalSince1970: 1000)
        func response(_ code: Int, _ headers: [String: String]) -> HTTPStatusError {
            HTTPStatusError.response(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!, now: clock)
        }
        let denied = response(403, [:]); XCTAssertFalse(denied.rateLimited); XCTAssertNil(denied.retryAt)
        let limited = response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1300", "Retry-After": "60"])
        XCTAssertTrue(limited.rateLimited); XCTAssertEqual(limited.retryAt, clock.addingTimeInterval(300))
        XCTAssertEqual(response(429, ["Retry-After": "Thu, 01 Jan 1970 00:20:00 GMT"]).retryAt, Date(timeIntervalSince1970: 1200))
        XCTAssertNil(response(403, ["Retry-After": "NaN"]).retryAt)
        let encoded = String(decoding: try JSONEncoder().encode(DiagnosticIssue(limited)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("github.com")); XCTAssertTrue(encoded.contains("rateLimited"))
    }
    func testCancellationStopsAnOriginQueueWaitWithoutIssuingRequest() async throws {
        let blocker = MetadataBlocker()
        let client = SourceHTTPClient(transport: { _, _, _ in await blocker.hold(); return .init(data: Data(), status: 200, headers: [:]) })
        let url = url
        let first = Task { try await client.data(from: url, limit: 10) }
        await blocker.waitForEntry()
        let waiting = Task { try await client.data(from: url, limit: 10) }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled waiter must stop") } catch { XCTAssertTrue(error is CancellationError) }
        await blocker.release(); _ = try await first.value
    }
}

private actor MetadataReplies {
    var replies: [Result<HTTPMetadataResponse, any Error>]
    var requests: [[String: String]] = []
    init(_ replies: [Result<HTTPMetadataResponse, any Error>]) { self.replies = replies }
    func next(_ url: URL, _ limit: Int, _ headers: [String: String]) throws -> HTTPMetadataResponse {
        requests.append(headers)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return try replies.removeFirst().get()
    }
}
private actor MetadataBlocker {
    private var gate: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { gate = $0; observer?.resume(); observer = nil } }
    func waitForEntry() async { if gate != nil { return }; await withCheckedContinuation { observer = $0 } }
    func release() { gate?.resume(); gate = nil }
}
