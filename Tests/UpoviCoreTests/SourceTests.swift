import XCTest
@testable import UpoviCore

final class SourceTests: XCTestCase {
    func testGnuCashReviewedStableMacRepackDoesNotRequireBetaOptIn() async throws {
        let url = "https://github.com/Gnucash/gnucash/releases/download/5.17/Gnucash-Arm-5.17-1.dmg"
        let cask = Data("{\"token\":\"gnucash\",\"version\":\"5.17-1\",\"url\":\"\(url)\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"artifacts\":[{\"app\":[\"Gnucash.app\"]}]}".utf8)
        let app = InstalledApp(name: "GnuCash fixture", bundleID: "org.gnucash.Gnucash", version: "5.15-1", build: "5.15-1",
                               path: "/synthetic/Gnucash.app", teamID: "Y9EHT5WMK7")
        let result = await UpdateChecker.check(app, fetch: { _, _ in cask }, catalog: { _ in nil })
        let item = try XCTUnwrap(BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first)
        XCTAssertEqual(item.candidate.version, "5.17-1")
        XCTAssertEqual(item.candidate.releaseChannel, .stable)
        XCTAssertFalse(item.candidate.isPrerelease)
        XCTAssertTrue(item.candidate.isReviewedStablePackaging == true)
        XCTAssertTrue(item.canInstall)
        XCTAssertTrue(VersionOrder.isPrerelease("5.17-1"), "Global numeric prerelease rules stay conservative")
        let unrelated = UpdateCandidate(version: "2.0-beta.1", source: "Unreviewed fixture", isCommunity: false, url: nil, releaseChannel: .stable)
        XCTAssertTrue(unrelated.isPrerelease, "A channel label alone cannot hide a prerelease marker")
        for other in ["https://github.com/Gnucash/gnucash/releases/download/5.17-1/Gnucash-Arm-5.17-1.dmg",
                      "https://github.com/unrelated/gnucash/releases/download/5.17/Gnucash-Arm-5.17-1.dmg"] {
            XCTAssertFalse(ApplicationSourceCatalog.isReviewedStablePackaging(for: app, sourceVersion: "5.17-1", download: URL(string: other)))
        }
        XCTAssertFalse(ApplicationSourceCatalog.isReviewedStablePackaging(for: app, sourceVersion: "5.18-1", download: URL(string: url)))
    }
    func testReviewedNetNewsWireRouteDoesNotMatchLookalikes() throws {
        let json = #"[{"token":"netnewswire","version":"7.2.1","artifacts":[{"app":["NetNewsWire.app"]}]}]"#
        let casks = try JSONDecoder().decode([CaskMetadata].self, from: Data(json.utf8))
        let app = InstalledApp(name: "Renamed", bundleID: "com.ranchero.NetNewsWire-Evergreen", version: "7.2", path: "/synthetic/Renamed.app")
        XCTAssertEqual(CaskCatalog.resolve(app, in: casks)?.token, "netnewswire")
        let lookalike = InstalledApp(name: "NetNewsWire", bundleID: "com.unrelated.NetNewsWire", version: "7.2", path: "/synthetic/NetNewsWire.app")
        XCTAssertNil(CaskCatalog.resolve(lookalike, in: casks))
    }
    func testNetNewsWireUsesReviewedChecksumSourceWhenPrefixedGitHubTagCannotBeCompared() async throws {
        let cask = Data(#"{"token":"netnewswire","version":"7.2.1","url":"https://github.com/Ranchero-Software/NetNewsWire/releases/download/mac-7.2.1/NetNewsWire7.2.1.zip","sha256":"9459896e516ac6c34685b38111dc456a3d1a4e49c964e40bc8f8af8fdc3b17db","artifacts":[{"app":["NetNewsWire.app"]}]}"#.utf8)
        let github = Data(#"{"tag_name":"mac-7.2.1","html_url":"https://github.com/Ranchero-Software/NetNewsWire/releases/tag/mac-7.2.1","draft":false,"prerelease":false,"assets":[]}"#.utf8)
        for version in ["7.2", "7.2.1"] {
            let app = InstalledApp(name: "NetNewsWire fixture", bundleID: "com.ranchero.NetNewsWire-Evergreen", version: version,
                                   build: "7220", path: "/synthetic/NetNewsWire.app", teamID: "M8L2WTLA8W")
            let result = await UpdateChecker.check(app, fetch: { url, _ in url.host == "formulae.brew.sh" ? cask : github }, catalog: { _ in nil })
            XCTAssertTrue(result.checks.contains { $0.source == .homebrew && $0.outcome == .checked })
            let plan = BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: [])
            if version == "7.2" {
                XCTAssertEqual(plan.first?.candidate.version, "7.2.1")
                XCTAssertTrue(plan.first?.canInstall == true)
                XCTAssertEqual(plan.first?.candidate.download?.sha256, "9459896e516ac6c34685b38111dc456a3d1a4e49c964e40bc8f8af8fdc3b17db")
            } else { XCTAssertTrue(plan.isEmpty) }
        }
    }
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
    private func identityPathCask(_ path: Any, token: String = "synthetic-editor", filename: String = "Editor.app", disabled: Bool = false) throws -> CaskMetadata {
        try JSONDecoder().decode(CaskMetadata.self, from: JSONSerialization.data(withJSONObject: [
            "token": token, "version": "2.0", "disabled": disabled,
            "artifacts": [["app": [filename]], ["zap": [["trash": path]]]]
        ]))
    }
    func testExactCaskIdentityPathAlsoRequiresExactMainFilenameAndDoesNotEnterIDOnlyIndex() throws {
        let cask = try identityPathCask("~/Library/Preferences/org.synthetic.Editor.plist")
        let app = InstalledApp(name: "Editor", bundleID: "org.synthetic.Editor", version: "1", path: "/synthetic/Editor.app")
        XCTAssertEqual(CaskCatalog.resolve(app, in: [cask])?.token, cask.token)
        XCTAssertTrue(cask.bundleIDs.isEmpty, "Path references are not declared quit identifiers")
        XCTAssertNil(CaskCatalog.index([cask])[app.bundleID], "An ID-only caller cannot verify the main filename")
        let renamed = InstalledApp(name: "Editor", bundleID: app.bundleID, version: "1", path: "/synthetic/Renamed.app")
        XCTAssertNil(CaskCatalog.resolve(renamed, in: [cask]))
        let lookalike = InstalledApp(name: "Editor", bundleID: "org.unrelated.Editor", version: "1", path: app.path)
        XCTAssertNil(CaskCatalog.resolve(lookalike, in: [cask]))
    }
    func testCaskIdentityPathsRejectGlobsNestedPathsTemplatesAndOtherLibraryLocations() throws {
        let app = InstalledApp(name: "Editor", bundleID: "org.synthetic.Editor", version: "1", path: "/synthetic/Editor.app")
        for path in ["~/Library/Preferences/org.synthetic.*.plist", "~/Library/Preferences/ByHost/org.synthetic.Editor.plist",
                     "~/Library/Preferences/org.synthetic.Editor.plist.lockfile", "~/Library/Containers/org.synthetic.Editor/Data",
                     "/Users/synthetic/Library/Preferences/org.synthetic.Editor.plist", "~/Library/LaunchAgents/org.synthetic.Editor.plist",
                     "~/Library/Application Support/org.synthetic.Editor", "~/Library/Caches/org.synthetic.Editor\n",
                     "~/Library/Caches/org.synthetic.Editor/../org.synthetic.Editor", "$HOME/Library/Caches/org.synthetic.Editor"] {
            XCTAssertNil(CaskCatalog.resolve(app, in: [try identityPathCask(path)]), path)
        }
        for path in ["~/Library/Caches/org.synthetic.Editor", "~/Library/Containers/org.synthetic.Editor",
                     "~/Library/Saved Application State/org.synthetic.Editor.savedState", "~/Library/Application Scripts/org.synthetic.Editor"] {
            XCTAssertEqual(CaskCatalog.resolve(app, in: [try identityPathCask([path])])?.token, "synthetic-editor")
        }
    }
    func testAmbiguousIdentityPathsAndInactiveChannelsStayUnresolved() throws {
        let path = "~/Library/Caches/org.synthetic.Editor"
        let first = try identityPathCask(path, token: "first"), second = try identityPathCask(path, token: "second")
        let app = InstalledApp(name: "Editor", bundleID: "org.synthetic.Editor", version: "1", path: "/synthetic/Editor.app")
        XCTAssertNil(CaskCatalog.resolve(app, in: [first, second]))
        XCTAssertEqual(CaskCatalog.resolve(app, in: [first, try identityPathCask(path, token: "second@beta")])?.token, "first")
        XCTAssertEqual(CaskCatalog.resolve(app, in: [first, try identityPathCask(path, token: "second", disabled: true)])?.token, "first")
        XCTAssertEqual(CaskCatalog.resolve(app, in: [first, try identityPathCask(path, token: "second", filename: "Other.app")])?.token, "first")
    }
    func testOversizedOrUnsupportedIdentityPathMetadataDoesNotBreakTheCaskCatalog() throws {
        let app = InstalledApp(name: "Editor", bundleID: "org.synthetic.Editor", version: "1", path: "/synthetic/Editor.app")
        let huge = try identityPathCask(Array(repeating: "~/Library/Caches/org.synthetic.Editor", count: 257))
        XCTAssertNil(CaskCatalog.resolve(app, in: [huge]))
        let odd = try JSONDecoder().decode(CaskMetadata.self, from: Data(#"{"token":"odd","version":"2","artifacts":[{"app":["Editor.app"]},{"zap":{"unrecognized":"format"}}]}"#.utf8))
        XCTAssertEqual(odd.applicationNames, ["Editor.app"])
        XCTAssertTrue(odd.bundleIdentityReferences.isEmpty)
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

extension SourceTests {
    func testGitHubRateLimitFallsBackToCanonicalLatestStablePageWithoutDownloadProof() async throws {
        let deadline = Date().addingTimeInterval(300)
        let release = try await GitHubRelease.latest(repository: "a/b", fetch: { url, _ in
            if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 403, retryAt: deadline, rateLimited: true) }
            if url.path.contains("/expanded_assets/") { throw HTTPStatusError(statusCode: 404) }
            XCTAssertEqual(url.absoluteString, "https://github.com/a/b/releases/latest")
            return Data(#"<html><head><meta property="og:url" content="https://github.com/a/b/releases/tag/v2.0"></head><body></body></html>"#.utf8)
        })
        XCTAssertEqual(release.version, "2.0"); XCTAssertNil(release.download)
        XCTAssertTrue(release.assets.isEmpty); XCTAssertEqual(release.rateLimitIssue?.rateLimited, true)
        XCTAssertEqual(release.rateLimitIssue?.retryAt, deadline)
        let app = InstalledApp(name: "Audiout", bundleID: "com.audiout.Audiout", version: "1", path: "/synthetic/Audiout.app")
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 403, retryAt: deadline, rateLimited: true) }
            return Data(#"<html><head><meta content="https://github.com/aa-hh/Audiout/releases/tag/v2.0" property="og:url"></head></html>"#.utf8)
        }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .partial); XCTAssertEqual(result.candidates.first?.version, "2.0")
        XCTAssertEqual(result.checks.first(where: { $0.source == .github })?.outcome, .failed)
        XCTAssertEqual(result.checks.first(where: { $0.source == .githubPage })?.outcome, .checked)
        XCTAssertEqual(BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first?.canInstall, false)
    }
    func testGitHubFallbackRejectsAmbiguousForeignPrereleaseAndBodyInjectedMetadata() throws {
        func page(_ urls: [String], body: String = "") -> Data {
            Data(("<html><head>" + urls.map { "<meta property=\"og:url\" content=\"\($0)\">" }.joined() + "</head><body>" + body + "</body></html>").utf8)
        }
        let valid = "https://github.com/a/b/releases/tag/v2.0"
        XCTAssertNoThrow(try GitHubRelease.publicStable(page([valid]), repository: "a/b"))
        XCTAssertEqual(try GitHubRelease.publicStable(page(["/a/b/releases/tag/v2.0"]), repository: "a/b").page.absoluteString, valid)
        for urls in [[valid, valid], ["https://github.com/other/repo/releases/tag/v2.0"], ["https://github.com/a/b/releases/tag/v2.0-beta.1"],
                     ["http://github.com/a/b/releases/tag/v2.0"], ["//other.example/a/b/releases/tag/v2.0"], ["https://github.com/a/b/releases/tag/v2.0?token=private"]] {
            XCTAssertThrowsError(try GitHubRelease.publicStable(page(urls), repository: "a/b"))
        }
        XCTAssertThrowsError(try GitHubRelease.publicStable(page([], body: "<meta property=\"og:url\" content=\"\(valid)\">"), repository: "a/b"))
    }
    func testPlainGitHubDenialAndBetaDoNotUseAnUnconfirmedFallback() async {
        for (channel, limited) in [(ReleaseChannel.stable, false), (.beta, true)] {
            do {
                _ = try await GitHubRelease.latest(repository: "a/b", channel: channel, fetch: { url, _ in
                    XCTAssertEqual(url.host, "api.github.com")
                    throw HTTPStatusError(statusCode: 403, rateLimited: limited)
                })
                XCTFail("An inaccessible or unconfirmed channel cannot be guessed")
            } catch { XCTAssertEqual((error as? HTTPStatusError)?.statusCode, 403) }
        }
    }
    func testAuthoritativeCurrentAppcastAvoidsRedundantGitHubAPIRequests() async throws {
        let app = InstalledApp(name: "Rectangle", bundleID: "com.knollsoft.Rectangle", version: "2.0", build: "2",
            path: "/synthetic/Rectangle.app", teamID: "SYNTHETIC1", feedURL: URL(string: "https://vendor.invalid/appcast.xml"))
        let feed = Data(#"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://vendor.invalid/App.zip" sparkle:version="2" sparkle:shortVersionString="2.0" /></item></channel></rss>"#.utf8)
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            XCTAssertEqual(url.host, "vendor.invalid", "The authoritative feed already confirmed the installed version")
            return feed
        }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .current)
        XCTAssertFalse(result.checks.contains { $0.source == .github })
    }
}
