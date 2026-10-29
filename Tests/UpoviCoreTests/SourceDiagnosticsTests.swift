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
    func testExtensionlessCaskDownloadsDeferTheirFormatToTheVerifiedBytes() throws {
        let hash = String(repeating: "a", count: 64)
        func cask(_ url: String, artifact: String = #"{"app":["App.app"]}"#, sha: String = hash) throws -> CaskMetadata {
            try JSONDecoder().decode(CaskMetadata.self, from: Data("""
            {"token":"fixture","version":"2","url":"\(url)","sha256":"\(sha)","artifacts":[\(artifact)]}
            """.utf8))
        }
        // VS Code's cask URL ends in /stable and redirects to a ZIP.
        let code = try XCTUnwrap(try cask("https://update.code.visualstudio.com/1.144.0/darwin-arm64/stable").download(intel: false, osMajor: 26))
        XCTAssertNil(code.declaredFormat); XCTAssertTrue(code.formatResolvableAfterDownload)
        XCTAssertNotNil(try cask("https://example.com/dl?product=desktop&version=2").download(intel: false, osMajor: 26))
        XCTAssertNil(try cask("https://example.com/App-2.tar.gz").download(intel: false, osMajor: 26))
        XCTAssertNil(try cask("https://example.com/stable", sha: "no_check").download(intel: false, osMajor: 26))
        XCTAssertNil(try cask("https://example.com/stable", artifact: #"{"pkg":["App.pkg"]}"#).download(intel: false, osMajor: 26))
        XCTAssertEqual(try cask("https://example.com/App.dmg").download(intel: false, osMajor: 26)?.declaredFormat, "dmg")
    }
    func testDownloadFormatIsSniffedFromContents() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-sniff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ data: Data) throws -> URL { let url = root.appending(path: name); try data.write(to: url); return url }
        XCTAssertEqual(DownloadDescriptor.sniffFormat(of: try file("a", Data([0x50, 0x4b, 0x03, 0x04]) + Data(count: 600))), "zip")
        XCTAssertEqual(DownloadDescriptor.sniffFormat(of: try file("b", Data("xar!".utf8) + Data(count: 600))), "pkg")
        XCTAssertEqual(DownloadDescriptor.sniffFormat(of: try file("c", Data(count: 1000) + Data("koly".utf8) + Data(count: 508))), "dmg")
        XCTAssertNil(DownloadDescriptor.sniffFormat(of: try file("d", Data([0x1f, 0x8b, 0x08, 0x00]) + Data(count: 600))))
        // A real compressed disk image, the format apps are distributed in.
        let image = root.appending(path: "real"), folder = root.appending(path: "Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: folder.appending(path: "file"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-srcfolder", folder.path, "-format", "UDZO", "-volname", "Fixture", "-ov", image.path + ".dmg"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(DownloadDescriptor.sniffFormat(of: URL(fileURLWithPath: image.path + ".dmg")), "dmg")
    }
    func testVSCodiumMappingRequiresItsExactStableBundleIdentity() throws {
        let data = Data(#"[{"token":"vscodium","version":"2","artifacts":[{"app":["VSCodium.app"]}]}]"#.utf8)
        let casks = try JSONDecoder().decode([CaskMetadata].self, from: data)
        XCTAssertEqual(CaskCatalog.resolve(.init(name: "Renamed", bundleID: "com.vscodium", version: "1", path: "/Renamed.app"), in: casks)?.token, "vscodium")
        XCTAssertNil(CaskCatalog.resolve(.init(name: "VSCodium", bundleID: "com.vscodium.VSCodiumInsiders", version: "1", path: "/VSCodium.app"), in: casks))
    }
}
