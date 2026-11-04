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
        let exhausted = URL(string: "https://\(UUID().uuidString).upovi.invalid/feed")!
        MetadataWire.state.set(exhausted, code: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1792618285"])
        let final = try await HTTPTransfer.metadata(from: exhausted, limit: 100, headers: [:], configuration: config)
        XCTAssertEqual(final.headers["x-ratelimit-remaining"], "0")
        XCTAssertEqual(final.headers["x-ratelimit-reset"], "1792618285")
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

extension SourceRefreshTests {
    private func steamFixture(build: String = "1785799196") throws -> (InstalledApp, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-steam-source-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "logs"), withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let launched = Date().addingTimeInterval(-60)
        try "[\(formatter.string(from: launched))] Client version: \(build)\n".write(to: root.appending(path: "logs/console_log.txt"), atomically: true, encoding: .utf8)
        let binary = package.deletingLastPathComponent().appending(path: "steamclient.dylib")
        try Data("fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.modificationDate: launched.addingTimeInterval(-600)], ofItemAtPath: binary.path)
        try Self.steamManifest(build).write(to: package.appending(path: "steam_client_signed-2_osx.manifest"))
        try Data("steamclient.dylib,7;123;456\n".utf8).write(to: package.appending(path: "steam_client_signed-2_osx.installed"))
        return (.init(name: "Steam", bundleID: "com.valvesoftware.steam", version: "6.1", build: "6.1", path: "/Applications/Steam.app", teamID: "MXGJJ98X76"), root)
    }
    private static func steamManifest(_ build: String) -> Data { Data("\"osx\"\n{\n\"version\" \"\(build)\"\n\"ostype\" \"macos1015\"\n}\n".utf8) }

    func testSteamComparesRealClientBuildInsteadOfUnchangedBootstrapVersion() async throws {
        let (app, root) = try steamFixture()
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            XCTAssertEqual(url, SteamUpdateSource.manifestURL); return Self.steamManifest("1792618285")
        }, catalog: { _ in XCTFail("Steam must not compare a Homebrew bootstrapper"); return nil }, steamRoot: root)
        XCTAssertEqual(result.status, .updates); XCTAssertEqual(result.installedVersion, "1785799196")
        XCTAssertEqual(UpdateAssessment(app: app, sourceResult: result).sourceUpdates.first?.version, "1792618285")
        let item = try XCTUnwrap(BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first)
        XCTAssertFalse(item.canInstall); XCTAssertNil(item.candidate.download)
        XCTAssertEqual(result.checks.first?.source, .steam)
    }
    func testSteamCurrentClientAndManifestFailureCannotBeConfused() async throws {
        let (app, root) = try steamFixture()
        let current = await SteamUpdateSource.check(app, root: root, fetch: { _, _ in Self.steamManifest("1785799196") })
        XCTAssertEqual(current.status, .current); XCTAssertTrue(current.candidates.isEmpty)
        let failed = await SteamUpdateSource.check(app, root: root, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.installedVersion, "1785799196")
    }
    func testSteamDoesNotMistakePendingManifestOrChangedBinaryForInstalledClient() async throws {
        let (app, root) = try steamFixture()
        let package = root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/package")
        try Self.steamManifest("1792618285").write(to: package.appending(path: "steam_client_signed-2_osx.manifest"))
        let pending = await SteamUpdateSource.check(app, root: root, fetch: { _, _ in XCTFail("Installed version was not corroborated"); return Data() })
        XCTAssertEqual(pending.status, .unsupported); XCTAssertTrue(pending.candidates.isEmpty)
        try Self.steamManifest("1785799196").write(to: package.appending(path: "steam_client_signed-2_osx.manifest"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: package.deletingLastPathComponent().appending(path: "steamclient.dylib").path)
        let changed = await SteamUpdateSource.check(app, root: root, fetch: { _, _ in XCTFail("Changed client requires a new launch record"); return Data() })
        XCTAssertEqual(changed.status, .unsupported)
    }
    func testSteamUnknownChannelMissingRecordAndMalformedManifestFailClosed() async throws {
        let (app, root) = try steamFixture()
        try "publicbeta".write(to: root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/package/beta"), atomically: true, encoding: .utf8)
        let beta = await SteamUpdateSource.check(app, root: root, fetch: { _, _ in XCTFail("A stable manifest cannot confirm a beta installation"); return Data() })
        XCTAssertEqual(beta.status, .unsupported)
        try FileManager.default.removeItem(at: root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/package/beta"))
        try FileManager.default.removeItem(at: root.appending(path: "logs/console_log.txt"))
        let unknown = await SteamUpdateSource.check(app, root: root, fetch: { _, _ in XCTFail("Do not infer a client build from 6.1"); return Data() })
        XCTAssertEqual(unknown.status, .unsupported)
        for text in ["", "<html>error</html>", "\"osx\" {\n\"version\" \"1792618285\"\n\"version\" \"1792618286\"\n}", "\"osx\" {\n\"version\" \"6.1\"\n}"] {
            XCTAssertThrowsError(try SteamUpdateSource.version(in: Data(text.utf8)))
        }
    }
    func testRetainedSourceEvidenceIsBoundedIdentityScopedAndCannotAuthorizeInstallation() throws {
        let app = InstalledApp(name: "Fixture", bundleID: "app.fixture.cache", version: "1", path: "/synthetic/Fixture.app", teamID: "SYNTHETIC1")
        let now = Date()
        let candidate = UpdateCandidate(version: "2", source: "GitHub Release", isCommunity: false, url: URL(string: "https://github.com/a/b/releases/tag/v2"),
            download: .init(url: URL(string: "https://github.com/a/b/releases/download/v2/App.zip")!, sha256: String(repeating: "a", count: 64)))
        var cache = SourceResultCache()
        cache.record(.init(appID: app.id, candidates: [candidate], note: "Confirmed", status: .updates, checks: [.init(.github, .checked)], checkedAt: now), app: app, sourceOverride: nil, now: now)
        cache = SourceResultCache(data: cache.encoded())
        let failure = SourceResult(appID: app.id, candidates: [], note: "Rate limited", status: .failed, checks: [.init(.github, .failed, error: HTTPStatusError(statusCode: 403, rateLimited: true))])
        let retained = cache.resolving(failure, app: app, sourceOverride: nil, now: now.addingTimeInterval(60))
        XCTAssertEqual(retained.status, .partial); XCTAssertEqual(retained.retainedFrom, now)
        XCTAssertEqual(retained.candidates.first?.requiresRevalidation, true); XCTAssertNil(retained.candidates.first?.download)
        XCTAssertEqual(BulkUpdatePlan.make(apps: [app], results: [app.id: retained], ignored: []).first?.canInstall, false)
        XCTAssertTrue(UpdateAssessment.notificationBatch(apps: [app], results: [app.id: retained], ignored: [], seen: []).isEmpty)
        XCTAssertTrue(cache.resolving(failure, app: app, sourceOverride: nil, now: now.addingTimeInterval(86401)).candidates.isEmpty)
        XCTAssertTrue(cache.resolving(failure, app: app, sourceOverride: .init(releaseChannel: .beta), now: now).candidates.isEmpty)
        let changed = InstalledApp(name: app.name, bundleID: app.bundleID, version: "2", path: app.path, teamID: app.teamID)
        XCTAssertTrue(cache.resolving(failure, app: changed, sourceOverride: nil, now: now).candidates.isEmpty)
        let current = SourceResult(appID: app.id, candidates: [], note: "Current", status: .current, checks: [.init(.github, .checked)], checkedAt: now)
        cache.record(current, app: app, sourceOverride: nil, now: now)
        XCTAssertTrue(cache.resolving(failure, app: app, sourceOverride: nil, now: now).candidates.isEmpty)
    }
}
