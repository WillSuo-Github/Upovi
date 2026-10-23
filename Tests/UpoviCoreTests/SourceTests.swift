import XCTest
@testable import UpoviCore

final class SourceTests: XCTestCase {
    func testCatalogRequiresExactUnambiguousIdentifiers() throws {
        let json = #"[{"token":"one","version":"2","artifacts":[{"uninstall":[{"quit":["app.one","app.*"]}]}]},{"token":"two","version":"3","artifacts":[{"uninstall":[{"quit":"app.one"}]}]},{"token":"valid","version":"4","artifacts":[{"uninstall":[{"quit":"app.valid"}]}]}]"#
        let catalog = CaskCatalog.index(try JSONDecoder().decode([CaskMetadata].self, from: Data(json.utf8)))
        XCTAssertNil(catalog["app.one"]); XCTAssertNil(catalog["app.*"])
        XCTAssertEqual(catalog["app.valid"]?.token, "valid")
        XCTAssertNil(catalog["Valid"])
    }
    func testGitHubRepositoryValidationAndAmbiguousDownloads() throws {
        for repository in ["../repo", "a/b/c", "a/", "a/b?token=x", "https://github.com/a/b"] { XCTAssertFalse(GitHubRelease.validRepository(repository)) }
        XCTAssertTrue(GitHubRelease.validRepository("owner/repo-name"))
        let json = #"{"tag_name":"v2.0","html_url":"https://github.com/a/b/releases/tag/v2.0","draft":false,"prerelease":false,"assets":[{"name":"App.dmg","browser_download_url":"https://github.com/a/b/App.dmg","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "2.0"); XCTAssertNotNil(release.download)
        let noHash = json.replacingOccurrences(of: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", with: "")
        XCTAssertNil(try JSONDecoder().decode(GitHubRelease.self, from: Data(noHash.utf8)).download)
    }
    func testCommunityCandidatesCanNeverSupplyDownload() {
        let descriptor = DownloadDescriptor(url: URL(string: "https://example.com/update.zip")!, sha256: String(repeating: "a", count: 64))
        let candidate = UpdateCandidate(version: "2", source: "Peer", isCommunity: true, url: nil, download: descriptor)
        XCTAssertNil(candidate.download)
    }
    func testDeltaDoesNotReplaceFullAppcastDownload() throws {
        let signature = Data(repeating: 1, count: 64).base64EncodedString()
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure sparkle:version="200" sparkle:shortVersionString="2.0" url="https://example.com/Full.zip" sparkle:edSignature="\(signature)" />
        <sparkle:deltas><enclosure sparkle:version="200" sparkle:shortVersionString="2.0" sparkle:deltaFrom="100" url="https://example.com/Delta.zip" sparkle:edSignature="\(signature)" /></sparkle:deltas>
        </item></channel></rss>
        """
        let result = try AppcastReader.read(Data(xml.utf8))
        XCTAssertEqual(result.first?.download?.url.lastPathComponent, "Full.zip")
    }
}
