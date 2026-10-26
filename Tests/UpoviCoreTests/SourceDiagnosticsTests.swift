import XCTest
@testable import UpoviCore

final class SourceDiagnosticsTests: XCTestCase {
    private let release = #"{"tag_name":"v2.0","html_url":"https://github.com/WillSuo-Github/livehub-desktop/releases/tag/v2.0","draft":false,"prerelease":false,"assets":[]}"#
    func testOfficialLiveHubRepositoryProducesAnUpdateWithoutAFeed() async {
        let app = InstalledApp(name: "Renamed", bundleID: "com.willsuo.livehub", version: "1.0", path: "/fixture.app")
        let data = Data(release.utf8)
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            XCTAssertEqual(url.path, "/repos/WillSuo-Github/livehub-desktop/releases/latest"); return data
        }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .updates); XCTAssertEqual(result.candidates.first?.version, "2.0")
        XCTAssertEqual(result.checks, [.init(.github, .checked)])
    }
    func testFailedFeedAndSuccessfulFallbackRemainPartialWithStructuredTLSError() async {
        let data = Data(release.utf8)
        let app = InstalledApp(name: "PlayCover", bundleID: "io.playcover.PlayCover", version: "1.0", path: "/fixture.app", feedURL: URL(string: "https://feed.invalid/private"))
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            if url.host == "feed.invalid" { throw URLError(.secureConnectionFailed) }; return data
        }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .partial); XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.checks.map(\.source), [.appcast, .github]); XCTAssertEqual(result.checks.first?.issue?.kind, .tls)
        let filtered = UpdatePolicy().filtering(result, app: app)
        XCTAssertEqual(filtered.checks, result.checks)
    }
    func testHTTPRateLimitIsRetainedWithoutInventingACompletedCheck() async {
        let app = InstalledApp(name: "LiveHub", bundleID: "com.willsuo.livehub", version: "1", path: "/fixture.app")
        let result = await UpdateChecker.check(app, fetch: { _, _ in throw HTTPStatusError(statusCode: 429) }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .failed); XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.checks.first?.issue?.httpStatus, 429)
    }
    func testUnrelatedIdentityNeverUsesCuratedRepositories() async {
        let app = InstalledApp(name: "LiveHub", bundleID: "dev.unrelated", version: "1", path: "/fixture.app")
        let result = await UpdateChecker.check(app, fetch: { _, _ in XCTFail("No repository belongs to this identity"); return Data() }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .unsupported); XCTAssertTrue(result.checks.isEmpty)
    }
    func testHeterogeneousApplicationArtifactsAndPlatformPackagingAreRespected() throws {
        let hash = String(repeating: "a", count: 64)
        let json = """
        {"token":"fixture","version":"2","url":"https://example.com/App.dmg","sha256":"\(hash)",
         "artifacts":[{"app":["Original.app",{"target":"Renamed.app"},42],"target":"/Applications/Installed.app"}],
         "variations":{"sonoma":{"artifacts":[{"pkg":["App.pkg"]}]}}}
        """
        let cask = try JSONDecoder().decode(CaskMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(cask.applicationNames, ["Installed.app", "Original.app", "Renamed.app"])
        XCTAssertNotNil(cask.download(intel: false, osMajor: 26)); XCTAssertNil(cask.download(intel: true, osMajor: 14))
        let unsafe = json.replacingOccurrences(of: "Original.app", with: "../Original.app").replacingOccurrences(of: "Renamed.app", with: "../Renamed.app").replacingOccurrences(of: "/Applications/Installed.app", with: "/private/Installed.app")
        XCTAssertTrue(try JSONDecoder().decode(CaskMetadata.self, from: Data(unsafe.utf8)).applicationNames.isEmpty)
    }
    func testVSCodiumMappingRequiresItsExactStableBundleIdentity() throws {
        let data = Data(#"[{"token":"vscodium","version":"2","artifacts":[{"app":["VSCodium.app"]}]}]"#.utf8)
        let casks = try JSONDecoder().decode([CaskMetadata].self, from: data)
        XCTAssertEqual(CaskCatalog.resolve(.init(name: "Renamed", bundleID: "com.vscodium", version: "1", path: "/Renamed.app"), in: casks)?.token, "vscodium")
        XCTAssertNil(CaskCatalog.resolve(.init(name: "VSCodium", bundleID: "com.vscodium.VSCodiumInsiders", version: "1", path: "/VSCodium.app"), in: casks))
    }
}
