import XCTest
@testable import UpoviCore

final class DownloadTrustTests: XCTestCase {
    private let official = URL(string: "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.50.1.zip")!
    private func app(team: String? = "Y93TK974AT", bundle: String = "com.bjango.istatmenus", store: Bool = false) -> InstalledApp {
        .init(name: "Fixture", bundleID: bundle, version: "7.30", path: "/nonexistent/Fixture.app", teamID: team, isAppStore: store)
    }
    private func candidate(_ version: String = "8.0", build: String = "", download: DownloadDescriptor? = nil) -> UpdateCandidate {
        .init(version: version, build: build, source: "Fixture", isCommunity: false, url: nil, download: download)
    }
    func testTyporaUsesExactIdentityWithoutNameMatching() throws {
        let cask = try JSONDecoder().decode(CaskMetadata.self, from: Data(#"{"token":"typora","version":"1.14.15","artifacts":[{"app":["Typora.app"]}]}"#.utf8))
        XCTAssertEqual(CaskCatalog.resolve(app(bundle: "abnerworks.Typora"), in: [cask])?.token, "typora")
        XCTAssertNil(CaskCatalog.resolve(app(bundle: "com.unrelated.Typora"), in: [cask]))
    }
    func testSignatureOnlyPolicyBindsDeveloperIdentityAndOfficialURL() {
        XCTAssertTrue(DownloadDescriptor(url: official).canVerify(for: app()))
        XCTAssertFalse(DownloadDescriptor(url: official).hasIntegrityProof)
        for installed in [app(team: nil), app(team: "OTHERTEAM1"), app(bundle: "com.lookalike"), app(store: true)] {
            XCTAssertFalse(DownloadDescriptor(url: official).canVerify(for: installed))
        }
        for text in [
            "http://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.zip",
            "https://cdn.istatmenus.app.evil.example/files/istatmenus7/versions/iStatMenus7.zip",
            "https://user:password@cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.zip",
            "https://cdn.istatmenus.app:8443/files/istatmenus7/versions/iStatMenus7.zip",
            "https://cdn.istatmenus.app/elsewhere/iStatMenus7.zip",
            "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7/../payload.zip",
            "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.pkg",
            "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.zip?redirect=evil"
        ] {
            XCTAssertFalse(DownloadDescriptor(url: URL(string: text)!).canVerify(for: app()), text)
        }
        XCTAssertFalse(DownloadDescriptor(url: official, sha256: "malformed").canVerify(for: app()))
        XCTAssertFalse(DownloadDescriptor(url: official, edSignature: Data([0])).canVerify(for: app()))
    }
    func testChromeNoCheckCaskBindsGoogleTeamAndStableDownloadPath() throws {
        let json = #"{"token":"google-chrome","version":"156.0.8078.74","url":"https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg","sha256":"no_check","artifacts":[{"app":["Google Chrome.app"]}]}"#
        let cask = try JSONDecoder().decode(CaskMetadata.self, from: Data(json.utf8))
        let chrome = app(team: "EQHXZ8M8AV", bundle: "com.google.Chrome")
        XCTAssertNil(cask.download)
        XCTAssertNotNil(cask.download(for: chrome))
        for installed in [app(team: "Y93TK974AT", bundle: "com.google.Chrome"), app(team: nil, bundle: "com.google.Chrome"),
                          app(team: "EQHXZ8M8AV", bundle: "com.google.Chrome.canary")] {
            XCTAssertNil(cask.download(for: installed))
        }
        for text in ["https://dl.google.com/chrome/mac/universal/beta/googlechrome.dmg",
                     "https://dl.google.com.evil.example/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
                     "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.pkg"] {
            XCTAssertFalse(DownloadDescriptor(url: URL(string: text)!).canVerify(for: chrome), text)
        }
    }
    func testCaskNoCheckRequiresReviewedDirectApplicationAndNeverDowngradesMalformedProof() throws {
        let json = #"{"token":"istat-menus","version":"7.50.1","url":"https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.50.1.zip","sha256":"no_check","artifacts":[{"app":["iStat Menus.app"]}]}"#
        let cask = try JSONDecoder().decode(CaskMetadata.self, from: Data(json.utf8))
        XCTAssertNil(cask.download)
        XCTAssertNotNil(cask.download(for: app()))
        XCTAssertNil(cask.download(for: app(team: nil)))
        for invalid in [json.replacingOccurrences(of: "no_check", with: "malformed"),
                        json.replacingOccurrences(of: #""app":["iStat Menus.app"]"#, with: #""pkg":["Installer.pkg"]"#)] {
            XCTAssertNil(try JSONDecoder().decode(CaskMetadata.self, from: Data(invalid.utf8)).download(for: app()))
        }
    }
    func testAppcastTargetCanUseSameVersionCaskProofWithoutDroppingExpectedBuild() {
        let descriptor = DownloadDescriptor(url: URL(string: "https://downloads.typora.io/mac/Typora-1.14.15.dmg")!, sha256: String(repeating: "a", count: 64))
        let target = candidate("1.14.15", build: "1234"), cask = candidate("1.14.15", download: descriptor)
        let result = UpdateChecker.supplementDownloads([target, cask], for: app(bundle: "abnerworks.Typora"))
        XCTAssertEqual(result[0].download, descriptor)
        XCTAssertEqual(result[0].build, "1234")
        XCTAssertEqual(result[0].source, target.source)
        for other in [candidate("1.14.14", download: descriptor), candidate("1.14.15", build: "9999", download: descriptor)] {
            XCTAssertNil(UpdateChecker.supplementDownloads([target, other], for: app())[0].download)
        }
        let ambiguous = candidate("1.14.15", download: .init(url: URL(string: "https://example.com/other.dmg")!, sha256: String(repeating: "b", count: 64)))
        XCTAssertNil(UpdateChecker.supplementDownloads([target, cask, ambiguous], for: app())[0].download)
        var peer = UpdateCandidate(version: "1.14.15", source: "Peer", isCommunity: true, url: nil)
        peer.download = descriptor
        XCTAssertNil(UpdateChecker.supplementDownloads([target, peer], for: app())[0].download)
        var buildOnly = target; buildOnly.usesBuildVersion = true
        XCTAssertNil(UpdateChecker.supplementDownloads([buildOnly, cask], for: app())[0].download)
    }
    func testUnprovenDownloadCannotUseForgedInstalledMetadataAsTrustAnchor() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("untrusted".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try BundleVerifier.validateDownload(file, descriptor: .init(url: official), app: app()))
        XCTAssertThrowsError(try BundleVerifier.verifyArchive(file, descriptor: .init(url: official), app: app()))
    }
    func testBulkPlanAllowsReviewedSignatureRouteButRejectsUnknownDeveloper() {
        let target = candidate(download: .init(url: official))
        for (installed, allowed) in [(app(), true), (app(team: nil), false)] {
            let plan = BulkUpdatePlan.make(apps: [installed], results: [installed.id: .init(appID: installed.id, candidates: [target], note: "Fixture", status: .updates)], ignored: [])
            XCTAssertEqual(plan.first?.canInstall, allowed)
        }
    }
    func testReviewedPackagingExceptionUsesExactBundleVersionAndBuildWithoutRepeatUpdate() async throws {
        let json = #"{"token":"istat-menus","version":"7.50.1","url":"https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.50.1.zip","sha256":"no_check","artifacts":[{"app":["iStat Menus.app"]}]}"#
        let payload = Data(json.utf8)
        let old = app()
        let result = await UpdateChecker.check(old, fetch: { _, _ in payload }, catalog: { _ in XCTFail("Known identity should use its exact cask endpoint"); return nil })
        XCTAssertEqual(result.candidates.first?.version, "7.50")
        XCTAssertEqual(result.candidates.first?.build, "2356")
        XCTAssertNotNil(result.candidates.first?.download)
        let current = InstalledApp(name: old.name, bundleID: old.bundleID, version: "7.50", build: "2356", path: old.path, teamID: old.teamID)
        let refreshed = await UpdateChecker.check(current, fetch: { _, _ in payload }, catalog: { _ in nil })
        XCTAssertEqual(refreshed.status, .current)
        XCTAssertTrue(refreshed.candidates.isEmpty)
        XCTAssertNil(ApplicationSourceCatalog.bundleRelease(for: old, sourceVersion: "7.50.2", download: official))
        XCTAssertNil(ApplicationSourceCatalog.bundleRelease(for: app(team: "OTHERTEAM1"), sourceVersion: "7.50.1", download: official))
        XCTAssertNil(ApplicationSourceCatalog.bundleRelease(for: old, sourceVersion: "7.50.1", download: URL(string: "https://example.com/Other.zip")))
    }
    func testTyporaSourceFillsMissingAppcastDownloadWithLiveCaskMetadata() async {
        let xml = Data(#"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="7789" sparkle:shortVersionString="1.14.15" url="https://downloads.typora.io/mac/Typora-1.14.15.dmg" /></item></channel></rss>"#.utf8)
        let json = Data(#"{"token":"typora","version":"1.14.15","url":"https://downloads.typora.io/mac/Typora-1.14.15.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifacts":[{"app":["Typora.app"]}]}"#.utf8)
        let installed = InstalledApp(name: "Renamed", bundleID: "abnerworks.Typora", version: "1.14.9", build: "7785", path: "/fixture.app", teamID: "9HWK5273G4", feedURL: URL(string: "https://typora.io/releases/macos.xml"))
        let result = await UpdateChecker.check(installed, fetch: { url, _ in url.host == "typora.io" ? xml : json }, catalog: { _ in XCTFail("Use the exact Typora identity"); return nil })
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.first?.build, "7789")
        XCTAssertTrue(result.candidates.allSatisfy { $0.download?.hasIntegrityProof == true })
    }
    func testDownloadRecordWaitsForPayloadVerificationAndRestartRequiresRecheck() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "upovi-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appending(path: "tasks.json")
        let center = DownloadCoordinator(storageURL: storage) { _, _, target, _, _, _ in try Data("fixture".utf8).write(to: target) }
        let id = try await center.download(.init(url: official), app: app(), to: root.appending(path: "Update.zip"), progress: { _, _ in })
        let downloaded = await center.snapshot().first?.state
        XCTAssertEqual(downloaded, .downloaded)
        let restarted = DownloadCoordinator(storageURL: storage) { _, _, _, _, _, _ in XCTFail("Restart must not download automatically") }
        let interrupted = await restarted.snapshot().first?.state
        XCTAssertEqual(interrupted, .interrupted)
        await center.finishApplicationVerification(id, error: PeerError.invalid("Rejected payload"))
        let rejected = await center.snapshot().first
        XCTAssertEqual(rejected?.state, .failed)
        XCTAssertNotNil(rejected?.issue)
        // Late callbacks cannot relabel an already rejected payload as verified.
        await center.finishApplicationVerification(id)
        let final = await center.snapshot().first?.state
        XCTAssertEqual(final, .failed)
        let accepted = try await center.download(.init(url: official), app: app(), to: root.appending(path: "Accepted.zip"), progress: { _, _ in })
        await center.finishApplicationVerification(accepted)
        let success = await center.snapshot().first?.state
        XCTAssertEqual(success, .verified)
    }
}
