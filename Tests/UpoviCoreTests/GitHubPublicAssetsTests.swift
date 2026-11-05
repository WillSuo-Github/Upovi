import XCTest
@testable import UpoviCore

final class GitHubPublicAssetsTests: XCTestCase {
    private static let digest = String(repeating: "a", count: 64)
    private static let page = Data(#"<html><head><meta property="og:url" content="https://github.com/a/b/releases/tag/v2.0"></head><body></body></html>"#.utf8)
    private static func row(_ name: String = "App.dmg", digest: String? = digest) -> String {
        let proof = digest.map { #"<span class="Truncate-text">sha256:\#($0)</span><clipboard-copy aria-label="Copy to clipboard digest for \#(name)" value="sha256:\#($0)"></clipboard-copy>"# } ?? ""
        return #"<li class="Box-row d-flex"><a href="/a/b/releases/download/v2.0/\#(name)">\#(name)</a>\#(proof)</li>"#
    }
    private func parse(_ html: String) throws -> [GitHubRelease.Asset] {
        try GitHubRelease.publicAssets(Data(html.utf8), repository: "a/b", tag: "v2.0")
    }
    func testOnlyExactAssetRowAndVisiblePlatformDigestBecomeDownloadProof() throws {
        let html = "<div><ul>" + Self.row("Update.delta") + Self.row() + #"<li class="Box-row"><a href="/a/b/archive/refs/tags/v2.0.zip">Source</a></li></ul></div>"#
        let assets = try parse(html)
        XCTAssertEqual(assets.count, 2)
        let release = GitHubRelease(tag_name: "v2.0", html_url: URL(string: "https://github.com/a/b/releases/tag/v2.0")!, draft: false, prerelease: false, assets: assets, body: nil)
        XCTAssertEqual(release.download?.sha256, Self.digest)
        XCTAssertEqual(release.download?.url.absoluteString, "https://github.com/a/b/releases/download/v2.0/App.dmg")
        XCTAssertEqual(try parse(Self.row("App&amp;Tool.dmg")).first?.name, "App&Tool.dmg")
    }
    func testPublicAssetsRejectForeignIdentityAndMismatchedOrDuplicatedProof() throws {
        let valid = Self.row()
        for invalid in [
            valid.replacingOccurrences(of: "/a/b/", with: "/other/repo/"),
            valid.replacingOccurrences(of: "/v2.0/", with: "/v3.0/"),
            valid.replacingOccurrences(of: "digest for App.dmg", with: "digest for Other.dmg"),
            valid.replacingOccurrences(of: "value=\"sha256:a", with: "value=\"sha256:b"),
            Self.row(digest: "abc"), valid + valid,
            valid.replacingOccurrences(of: "href=", with: "href=\"/a/b/releases/download/v2.0/Other.dmg\" href="),
            valid.replacingOccurrences(of: "/a/b/releases/download/v2.0/App.dmg", with: "https://github.com:443/a/b/releases/download/v2.0/App.dmg"),
            valid.replacingOccurrences(of: "/v2.0/App.dmg", with: "/v2.0/App.dmg?token=private"),
            valid.replacingOccurrences(of: "/v2.0/App.dmg", with: "/v2.0/%2e%2e"),
            "<!--" + valid + "-->", "<html><body>" + valid + "</body></html>",
            "<script>" + valid + "</script>", "<template>" + valid + "</template>",
            valid.replacingOccurrences(of: "Box-row", with: "release-body"),
            String(repeating: " ", count: 65_537) + valid,
            String(repeating: valid, count: 201)
        ] { XCTAssertThrowsError(try parse(invalid), String(invalid.prefix(150))) }
    }
    func testMissingHashAndAmbiguousOrForeignPlatformAssetsStayManual() throws {
        func release(_ rows: String) throws -> GitHubRelease {
            .init(tag_name: "v2.0", html_url: URL(string: "https://github.com/a/b/releases/tag/v2.0")!, draft: false,
                  prerelease: false, assets: try parse(rows), body: nil)
        }
        XCTAssertNil(try release(Self.row(digest: nil)).download)
        XCTAssertNil(try release(Self.row() + Self.row("Other.dmg")).download)
        XCTAssertNil(try release(Self.row("App-linux.zip")).download)
        #if arch(arm64)
        XCTAssertNil(try release(Self.row("App-x86_64.dmg")).download)
        #else
        XCTAssertNil(try release(Self.row("App-arm64.dmg")).download)
        #endif
        XCTAssertEqual(try release(Self.row() + Self.row("App-linux.zip")).download?.sha256, Self.digest)
    }
    func testRateLimitUsesExactConfirmedTagAndRetainsFailureClassification() async throws {
        let release = try await GitHubRelease.latest(repository: "a/b", fetch: { url, _ in
            if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 429, rateLimited: true) }
            if url.path == "/a/b/releases/latest" { return Self.page }
            XCTAssertEqual(url.absoluteString, "https://github.com/a/b/releases/expanded_assets/v2.0")
            return Data(Self.row().utf8)
        })
        XCTAssertEqual(release.download?.sha256, Self.digest)
        XCTAssertTrue(release.publicAssetsChecked)
        XCTAssertNil(release.publicAssetsIssue)
        XCTAssertEqual(release.rateLimitIssue?.httpStatus, 429)
    }
    func testAssetFailureKeepsConfirmedVersionAndNeverCreatesDownload() async throws {
        let release = try await GitHubRelease.latest(repository: "a/b", fetch: { url, _ in
            if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 429, rateLimited: true) }
            if url.path == "/a/b/releases/latest" { return Self.page }
            throw HTTPStatusError(statusCode: 503)
        })
        XCTAssertEqual(release.version, "2.0"); XCTAssertNil(release.download)
        XCTAssertEqual(release.publicAssetsIssue?.httpStatus, 503)
        XCTAssertFalse(release.publicAssetsChecked)
    }
    func testFallbackCancellationIsNotSwallowedByRateLimit() async {
        for cancelPage in [false, true] {
            do {
                _ = try await GitHubRelease.latest(repository: "a/b", fetch: { url, _ in
                    if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 429, rateLimited: true) }
                    if !cancelPage && url.path == "/a/b/releases/latest" { return Self.page }
                    throw CancellationError()
                })
                XCTFail("Cancellation must propagate")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    func testRecoveredPublicProofRemainsVisibleInPartialSourceDiagnostics() async throws {
        let app = InstalledApp(name: "Audiout", bundleID: "com.audiout.Audiout", version: "1.0", path: "/synthetic/Audiout.app", teamID: "SYNTHETIC1")
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 429, rateLimited: true) }
            if url.path.hasSuffix("/latest") { return Data(String(decoding: Self.page, as: UTF8.self).replacingOccurrences(of: "a/b", with: "aa-hh/Audiout").utf8) }
            return Data(Self.row().replacingOccurrences(of: "a/b", with: "aa-hh/Audiout").utf8)
        }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.candidates.first?.download?.sha256, Self.digest)
        XCTAssertEqual(result.checks.first(where: { $0.source == .githubAssets })?.outcome, .checked)
        XCTAssertEqual(result.checks.first(where: { $0.source == .github })?.outcome, .failed)
    }
}
