import XCTest
@testable import UpoviCore

final class SourceTests: XCTestCase {
    func testCuratedCatalogDoesNotConfuseSameNamedProducts() throws {
        let json = #"[{"token":"orca","version":"1.3.1","artifacts":[{"app":["orca.app"]}]},{"token":"cursor","version":"3.0","artifacts":[{"app":["Cursor.app"]}]}]"#
        let casks = try JSONDecoder().decode([CaskMetadata].self, from: Data(json.utf8))
        let unrelated = InstalledApp(name: "Orca", bundleID: "com.stablyai.orca", version: "1", path: "/Applications/Orca.app")
        XCTAssertNil(CaskCatalog.resolve(unrelated, in: casks))
        let cursor = InstalledApp(name: "Renamed", bundleID: "com.todesktop.230313mzl4w4u92", version: "1", path: "/Applications/Renamed.app")
        XCTAssertEqual(CaskCatalog.resolve(cursor, in: casks)?.token, "cursor")
        let lookalike = InstalledApp(name: "Cursor", bundleID: "app.unrelated.Cursor", version: "1", path: "/Applications/Cursor.app")
        XCTAssertNil(CaskCatalog.resolve(lookalike, in: casks))
    }
    func testReusedBundleIdentityRequiresExactUnambiguousApplicationFilename() throws {
        let json = #"[{"token":"first","version":"2","artifacts":[{"app":["First.app"]},{"uninstall":[{"quit":"app.shared"}]}]},{"token":"second","version":"3","artifacts":[{"app":["Second.app"]},{"uninstall":[{"quit":"app.shared"}]}]}]"#
        let casks = try JSONDecoder().decode([CaskMetadata].self, from: Data(json.utf8))
        let app = InstalledApp(name: "First", bundleID: "app.shared", version: "1", path: "/Applications/First.app")
        XCTAssertEqual(CaskCatalog.resolve(app, in: casks)?.token, "first")
        let renamed = InstalledApp(name: "First", bundleID: "app.shared", version: "1", path: "/Applications/Renamed.app")
        XCTAssertNil(CaskCatalog.resolve(renamed, in: casks))
        XCTAssertNil(CaskCatalog.index(casks)["app.shared"])
    }
    func testCaskPlatformVersionAndHeterogeneousAppArtifacts() throws {
        let json = #"{"token":"app","version":"5.0","artifacts":[{"app":["App.app",{"target":"Renamed.app"}]}],"variations":{"sonoma":{"version":"4.5"},"arm64_sonoma":{"version":"4.9"}}}"#
        let cask = try JSONDecoder().decode(CaskMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(cask.platformVersion(intel: true, osMajor: 14), "4.5")
        XCTAssertEqual(cask.platformVersion(intel: false, osMajor: 14), "4.9")
        XCTAssertEqual(cask.platformVersion(intel: false, osMajor: 26), "5.0")
    }
    func testKnownPackagingVersionsCompareWithoutGuessingUnknownFormats() {
        XCTAssertEqual(VersionOrder.compare("3.6.9-e0ba6bb8", "3.6.9"), .orderedSame)
        XCTAssertEqual(VersionOrder.compare("7.2.2 (88465)", "7.2.2.88465"), .orderedSame)
        XCTAssertEqual(VersionOrder.compare("7.2.3.1", "7.2.2 (88465)"), .orderedDescending)
        XCTAssertFalse(SourceVersion.comparable("latest", installed: "1.0"))
        XCTAssertFalse(SourceVersion.comparable("8.1", installed: "Chromium custom build"))
        XCTAssertTrue(VersionOrder.isPrerelease("2.0-beta.1"))
        XCTAssertEqual(VersionOrder.compare("2.0-beta.1", "2.0"), .orderedAscending)
        XCTAssertEqual(VersionOrder.compare("6000.6.7f1", "Unity version 6000.6.0f1"), .orderedDescending)
        XCTAssertEqual(VersionOrder.compare("6000.6.7b1", "6000.6.7f1"), .orderedAscending)
        XCTAssertEqual(VersionOrder.compare("6000.6.7p1", "6000.6.7f1"), .orderedDescending)
    }
    func testPackageOnlyDiskImagesCannotOfferDirectApplicationReplacement() throws {
        let json = #"{"token":"package","version":"2","url":"https://example.com/Package.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifacts":[{"pkg":["Package.pkg"]}]}"#
        XCTAssertNil(try JSONDecoder().decode(CaskMetadata.self, from: Data(json.utf8)).download)
        let app = json.replacingOccurrences(of: #""pkg":["Package.pkg"]"#, with: #""app":["Application.app"]"#)
        XCTAssertNotNil(try JSONDecoder().decode(CaskMetadata.self, from: Data(app.utf8)).download)
    }
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

extension SourceTests {
    func testSparkleDisplayVersionCannotOfferTheAlreadyInstalledPlayCoverBuildAgain() async throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>1633</sparkle:version><sparkle:shortVersionString>4.0.0</sparkle:shortVersionString>
        <enclosure url="https://example.invalid/PlayCover_4.0.0-prerelease.dmg" />
        </item></channel></rss>
        """
        let offers = try AppcastReader.read(Data(xml.utf8))
        let app = InstalledApp(name: "PlayCover fixture", bundleID: "io.playcover.PlayCover", version: "3.1.0", build: "1633",
            path: "/synthetic/PlayCover.app", teamID: "792V9HMJW3", feedURL: URL(string: "https://example.invalid/appcast.xml"))
        let candidate = try XCTUnwrap(offers.first)
        XCTAssertEqual(candidate.version, "4.0.0")
        XCTAssertEqual(candidate.build, "1633")
        XCTAssertTrue(candidate.comparesUsingBuild)
        XCTAssertFalse(candidate.isNewer(than: app))
        let github = Data(#"{"tag_name":"3.1.0","html_url":"https://github.com/PlayCover/PlayCover/releases/tag/3.1.0","draft":false,"prerelease":false,"assets":[]}"#.utf8)
        let result = await UpdateChecker.check(app, fetch: { url, _ in url.host == "example.invalid" ? Data(xml.utf8) : github }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .current)
        XCTAssertFalse(UpdateAssessment(app: app, sourceResult: result).hasUpdate)
        XCTAssertTrue(BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).isEmpty)
    }

    func testAuthoritativeBuildOrdersUpdatesIndependentlyOfDisplayVersionAndSurvivesHistory() throws {
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.sparkle", version: "4.0", build: "100", path: "/synthetic/F.app")
        let newer = UpdateCandidate(version: "3.1", build: "101", source: "Developer appcast", isCommunity: false, url: nil, buildIsAuthoritative: true)
        XCTAssertTrue(newer.isNewer(than: app))
        let assessment = UpdateAssessment(app: app, sourceResult: .init(appID: app.id, candidates: [newer], note: "", status: .updates))
        XCTAssertEqual(assessment.sourceUpdates.count, 1)
        let encoded = try JSONEncoder().encode(newer)
        XCTAssertTrue(try JSONDecoder().decode(UpdateCandidate.self, from: encoded).comparesUsingBuild)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "buildIsAuthoritative")
        XCTAssertNil(try JSONDecoder().decode(UpdateCandidate.self, from: JSONSerialization.data(withJSONObject: legacy)).buildIsAuthoritative)
    }
}
