import XCTest
import CryptoKit
@testable import UpoviCore

final class ElectronSourceTests: XCTestCase, @unchecked Sendable {
    private let feed = URL(string: "https://example.com/releases/latest-mac.yml")!
    private var proof: String { Data(repeating: 7, count: 64).base64EncodedString() }
    private func manifest(_ extra: String = "") -> Data {
        Data("""
        version: 2.0.0
        files:
          - url: App-2.0.0-arm64.dmg
            sha512: \(proof)
            size: 100
          - url: App-2.0.0-x64.dmg
            sha512: \(proof)
            size: 100
        releaseDate: '2026-11-04T00:00:00Z'
        \(extra)
        """.utf8)
    }
    func testGenericAndGitHubConfigurationUseOnlyExplicitInstalledSources() throws {
        XCTAssertEqual(try ElectronUpdateSource.configuration(Data("provider: generic\nurl: https://example.com/releases\n".utf8)), .generic(URL(string: "https://example.com/releases")!))
        XCTAssertEqual(try ElectronUpdateSource.configuration(Data("owner: publisher\nrepo: app\nprovider: github\nreleaseType: release\n".utf8)), .github("publisher/app"))
        for config in ["provider: generic\nurl: https://updates.invalid/app", "provider: generic\nurl: http://example.invalid/", "provider: generic\nurl: https://user:password@example.invalid/",
                       "provider: generic\nurl: https://example.invalid/?token=secret", "provider: github\nowner: ../other\nrepo: app",
                       "provider: github\nowner: publisher\nrepo: app\nprivate: true", "provider: generic\nurl: https://example.invalid/\nchannel: beta",
                       "provider: generic\nurl: https://example.invalid/\nupdateManifestPublicKey: required"] {
            XCTAssertThrowsError(try ElectronUpdateSource.configuration(Data(config.utf8)))
        }
    }
    func testModernFilesChooseNativeArchitectureAndResolveRelativeArchives() throws {
        for (architecture, suffix) in [("arm64", "arm64.dmg"), ("x86_64", "x64.dmg")] {
            let candidate = try ElectronUpdateSource.read(manifest(), feed: feed, architecture: architecture)
            XCTAssertEqual(candidate.version, "2.0.0")
            XCTAssertEqual(candidate.download?.url.absoluteString, "https://example.com/releases/App-2.0.0-" + suffix)
            XCTAssertEqual(candidate.download?.sha512, proof)
            XCTAssertTrue(candidate.download?.hasIntegrityProof == true)
        }
    }
    func testLegacyMetadataAndQuotedScalarAreSupported() throws {
        let data = Data("version: '2.0.0'\npath: \"App.zip\"\nsha512: \(proof)\n".utf8)
        let candidate = try ElectronUpdateSource.read(data, feed: feed)
        XCTAssertEqual(candidate.download?.url.lastPathComponent, "App.zip")
        XCTAssertTrue(candidate.download?.hasIntegrityProof == true)
    }
    func testAmbiguousAndUnverifiableArchivesStayManual() throws {
        let duplicate = String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: "App-2.0.0-x64.dmg", with: "Other-2.0.0-arm64.dmg")
        XCTAssertNil(try ElectronUpdateSource.read(Data(duplicate.utf8), feed: feed, architecture: "arm64").download)
        let bad = manifest().replacingOccurrences(of: Data(proof.utf8), with: Data("invalid".utf8))
        XCTAssertNil(try ElectronUpdateSource.read(bad, feed: feed).download)
    }
    func testDuplicateFieldsAliasesTagsAndMalformedVersionsAreRejected() {
        for extra in ["version: 3.0.0", "other: &alias value\nreference: *alias", "other: !!str unsafe"] {
            XCTAssertThrowsError(try ElectronUpdateSource.read(manifest(extra), feed: feed))
        }
        for version in ["999999999999999999999999999999999", "2.0.0-beta.1", "latest", ""] {
            let text = String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: "version: 2.0.0", with: "version: " + version)
            XCTAssertThrowsError(try ElectronUpdateSource.read(Data(text.utf8), feed: feed))
        }
        XCTAssertThrowsError(try ElectronUpdateSource.read(manifest(), feed: feed, expectedVersion: "3.0.0"))
    }
    func testStagedSignedAndIncompatibleReleasesRequireTheApplicationsUpdater() throws {
        for extra in ["stagingPercentage: 10", "signature: required", "minimumSystemVersion: 999.0"] {
            XCTAssertThrowsError(try ElectronUpdateSource.read(manifest(extra), feed: feed, kernelVersion: "26.0.0"))
        }
        XCTAssertNoThrow(try ElectronUpdateSource.read(manifest("minimumSystemVersion: 23.0"), feed: feed, kernelVersion: "26.0.0"))
    }
    func testSHA512ProofRoundTripsIsRecheckedAndSeparatesCacheEntries() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = Data("verified Electron archive".utf8)
        try payload.write(to: file)
        let digest = Data(SHA512.hash(data: payload)).base64EncodedString()
        let descriptor = DownloadDescriptor(url: feed, sha512: digest)
        let decoded = try JSONDecoder().decode(DownloadDescriptor.self, from: JSONEncoder().encode(descriptor))
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.electron", version: "1", path: "/synthetic/F.app")
        XCTAssertEqual(decoded, descriptor)
        XCTAssertNoThrow(try BundleVerifier.verifyArchive(file, descriptor: decoded, app: app))
        XCTAssertNotEqual(ArtifactDownloadCache.key(decoded), ArtifactDownloadCache.key(.init(url: feed, sha512: proof)))
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try BundleVerifier.verifyArchive(file, descriptor: decoded, app: app))
        XCTAssertFalse(DownloadDescriptor(url: feed, sha512: "bad").canVerify(for: app))
    }
    func testOldDownloadRecordsWithoutSHA512RemainReadable() throws {
        let old = Data(#"{"url":"https://example.invalid/app.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        let descriptor = try JSONDecoder().decode(DownloadDescriptor.self, from: old)
        XCTAssertNil(descriptor.sha512); XCTAssertTrue(descriptor.hasIntegrityProof)
    }
    func testInstalledConfigurationCannotEscapeTheApplicationResources() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bundle = root.appending(path: "Fixture.app"), external = root.appending(path: "external")
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("provider: generic\nurl: https://example.com/releases\n".utf8).write(to: external.appending(path: "app-update.yml"))
        try FileManager.default.createSymbolicLink(at: bundle.appending(path: "Contents/Resources"), withDestinationURL: external)
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.electron", version: "1", path: bundle.path)
        XCTAssertThrowsError(try ElectronUpdateSource.installed(in: app))
    }
    func testGitHubManifestIsCheckedAndDuplicateManifestsCannotUseTheFallback() async throws {
        let source = ElectronUpdateSource.github("publisher/app"), manifest = manifest()
        for count in 0...2 {
            let asset: [String: Any] = ["name": "latest-mac.yml", "browser_download_url": "https://github.com/publisher/app/releases/download/v2.0.0/latest-mac.yml"]
            let response = try JSONSerialization.data(withJSONObject: ["tag_name": "v2.0.0", "html_url": "https://github.com/publisher/app/releases/tag/v2.0.0", "draft": false, "prerelease": false, "assets": Array(repeating: asset, count: count)])
            let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.electron", version: "1", path: "/synthetic/F.app")
            do {
                let result = try await source.check(app, fetch: { url, _ in
                    if url.host == "api.github.com" { return response }
                    XCTAssertEqual(url.lastPathComponent, "latest-mac.yml"); return manifest
                })
                XCTAssertLessThan(count, 2)
                XCTAssertEqual(result.version, "2.0.0")
                XCTAssertEqual(result.download?.sha512, count == 1 ? proof : nil)
            } catch { XCTAssertEqual(count, 2) }
        }
    }
    func testStagedFeedCannotBeBypassedByANewerCatalogVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-electron-\(UUID()).app")
        let resources = root.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("provider: generic\nurl: https://example.com/releases\n".utf8).write(to: resources.appending(path: "app-update.yml"))
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.electron", version: "1.0.0", path: root.path)
        let staged = manifest("stagingPercentage: 10")
        let cask = try JSONDecoder().decode(CaskMetadata.self, from: Data(#"{"token":"fixture","version":"3.0.0"}"#.utf8))
        let result = await UpdateChecker.check(app, fetch: { _, _ in staged }, catalog: { _ in cask })
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.checks.first?.outcome, .manual)
    }
    func testProductionCheckerUsesInstalledElectronFeedAndHonorsExplicitOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-electron-\(UUID()).app")
        let resources = root.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("provider: generic\nurl: https://example.com/releases\n".utf8).write(to: resources.appending(path: "app-update.yml"))
        let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.electron", version: "1.0.0", path: root.path)
        let data = manifest()
        let result = await UpdateChecker.check(app, fetch: { url, _ in
            XCTAssertEqual(url, URL(string: "https://example.com/releases/latest-mac.yml")!); return data
        }, catalog: { _ in nil })
        XCTAssertEqual(result.status, .updates)
        XCTAssertEqual(result.checks.first?.source, .electron)
        XCTAssertNotNil(result.candidates.first?.download?.sha512)
        let override = URL(string: "https://example.invalid/custom.xml")!
        let customized = await UpdateChecker.check(app, override: .init(appcast: override), fetch: { url, _ in
            XCTAssertEqual(url, override); return Data("<rss><channel/></rss>".utf8)
        }, catalog: { _ in nil })
        XCTAssertEqual(customized.status, .current)
        XCTAssertFalse(customized.checks.contains { $0.source == .electron })
    }
}

private extension Data {
    func replacingOccurrences(of needle: Data, with replacement: Data) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: String(decoding: needle, as: UTF8.self), with: String(decoding: replacement, as: UTF8.self)).utf8)
    }
}
