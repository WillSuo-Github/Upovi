import XCTest
@testable import UpoviCore

final class ReleaseChannelsAndAutomationTests: XCTestCase, @unchecked Sendable {
    private let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.auto", version: "1.0", build: "100", path: "/Applications/Fixture.app", teamID: "SYNTHETIC1")
    private var candidate: UpdateCandidate { .init(version: "2.0", source: "Fixture", isCommunity: false, url: nil,
        download: .init(url: URL(string: "https://example.com/app.dmg")!, sha256: String(repeating: "a", count: 64))) }
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> [String: Any] {
        ["tag_name": tag, "html_url": "https://github.com/publisher/app/releases/tag/" + tag, "prerelease": prerelease, "draft": draft, "assets": []]
    }
    func testStableUsesStableEndpointAndBetaSelectsNewestComparableNonDraftRelease() async throws {
        let stableData = try JSONSerialization.data(withJSONObject: release("v1.5"))
        let stable = try await GitHubRelease.latest(repository: "publisher/app", fetch: { url, _ in
            XCTAssertTrue(url.path.hasSuffix("/latest")); return stableData
        })
        XCTAssertEqual(stable.version, "1.5")
        let canonical = try await GitHubRelease.latest(repository: "Publisher/App", fetch: { _, _ in stableData })
        XCTAssertEqual(canonical.version, "1.5")
        let betaData = try JSONSerialization.data(withJSONObject: [release("v1.5"), release("v2.0-beta.2", prerelease: true), release("v99.0", draft: true), release("not-a-version", prerelease: true)])
        let beta = try await GitHubRelease.latest(repository: "publisher/app", channel: .beta, fetch: { url, _ in
            XCTAssertEqual(url.query, "per_page=50"); return betaData
        })
        XCTAssertEqual(beta.version, "2.0-beta.2"); XCTAssertTrue(beta.isPrerelease)
        do { _ = try await GitHubRelease.latest(repository: "other/app", fetch: { _, _ in stableData }); XCTFail("Cross-repository release accepted") }
        catch { }
        let duplicated = try JSONSerialization.data(withJSONObject: [release("v2.0-beta.2", prerelease: true), release("v2.0-beta.2", prerelease: true)])
        do { _ = try await GitHubRelease.latest(repository: "publisher/app", channel: .beta, fetch: { _, _ in duplicated }); XCTFail("Ambiguous release accepted") }
        catch { }
    }
    func testPrereleaseOptInDoesNotPermitDowngradesAndLegacySettingsDecodeAsStable() throws {
        let old = try JSONDecoder().decode(SourceOverride.self, from: Data(#"{"githubRepository":"publisher/app"}"#.utf8))
        XCTAssertNil(old.releaseChannel)
        XCTAssertFalse(VersionOrder.isNewer(version: "2.0-beta.2", than: app))
        XCTAssertTrue(VersionOrder.isNewer(version: "2.0-beta.2", than: app, allowPrerelease: true))
        XCTAssertFalse(VersionOrder.isNewer(version: "0.9-beta.2", than: app, allowPrerelease: true))
        XCTAssertTrue(VersionOrder.isPrerelease("26.10.0-0"))
        XCTAssertEqual(VersionOrder.compare("26.10.0-0", "26.10.0"), .orderedAscending)
        var beta = candidate; beta.releaseChannel = .beta
        let decoded = try JSONDecoder().decode(UpdateCandidate.self, from: JSONEncoder().encode(beta))
        XCTAssertTrue(decoded.isPrerelease); XCTAssertFalse(ReleaseChannel.stable.permits(decoded))
    }
    func testSparkleChannelFilteringAndProductionCheckerRequireExplicitOptIn() async throws {
        let xml = Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:shortVersionString>1.5</sparkle:shortVersionString><sparkle:version>150</sparkle:version></item>
        <item><sparkle:channel>beta</sparkle:channel><sparkle:shortVersionString>2.0-beta.2</sparkle:shortVersionString><sparkle:version>200</sparkle:version></item>
        <item><sparkle:channel>nightly</sparkle:channel><sparkle:shortVersionString>99.0</sparkle:shortVersionString><sparkle:version>9900</sparkle:version></item>
        </channel></rss>
        """.utf8)
        let installed = InstalledApp(name: app.name, bundleID: app.bundleID, version: app.version, build: app.build,
            path: app.path, teamID: app.teamID, feedURL: URL(string: "https://example.com/feed.xml"))
        let stable = await UpdateChecker.check(installed, fetch: { _, _ in xml }, catalog: { _ in nil })
        XCTAssertEqual(stable.candidates.map(\.version), ["1.5"])
        let beta = await UpdateChecker.check(installed, override: .init(releaseChannel: .beta), fetch: { _, _ in xml }, catalog: { _ in nil })
        XCTAssertEqual(Set(beta.candidates.map(\.version)), ["1.5", "2.0-beta.2"])
        XCTAssertTrue(beta.candidates.first(where: { $0.version == "2.0-beta.2" })?.isPrerelease == true)
    }
    func testElectronBetaUsesItsOwnManifestAndCannotRelaxStagingOrIntegrity() async throws {
        let source = ElectronUpdateSource.generic(URL(string: "https://example.com/releases")!)
        let hash = Data(repeating: 3, count: 64).base64EncodedString()
        let stable = Data("version: 1.5\npath: App.dmg\nsha512: \(hash)".utf8)
        let beta = Data("version: 2.0-beta.2\npath: App.dmg\nsha512: \(hash)".utf8)
        let chosen = try await source.check(app, channel: .beta, fetch: { url, _ in url.lastPathComponent == "beta-mac.yml" ? beta : stable })
        XCTAssertEqual(chosen.version, "2.0-beta.2"); XCTAssertTrue(chosen.isPrerelease)
        let betaOnly = try await source.check(app, channel: .beta, fetch: { url, _ in
            if url.lastPathComponent == "latest-mac.yml" { throw HTTPStatusError(statusCode: 404) }; return beta
        })
        XCTAssertTrue(betaOnly.isPrerelease)
        let defaultChoice = try await source.check(app, fetch: { url, _ in XCTAssertEqual(url.lastPathComponent, "latest-mac.yml"); return stable })
        XCTAssertFalse(defaultChoice.isPrerelease)
        XCTAssertThrowsError(try ElectronUpdateSource.read(beta, feed: URL(string: "https://example.com/latest-mac.yml")!))
        XCTAssertThrowsError(try ElectronUpdateSource.read(beta + Data("\nstagingPercentage: 5".utf8), feed: URL(string: "https://example.com/beta-mac.yml")!, channel: .beta))
    }
    func testBetaPayloadStillRequiresExactTargetAndInstallerPermission() {
        let incoming = InstalledApp(name: app.name, bundleID: app.bundleID, version: "2.0-beta.2", build: "200", path: "/synthetic/Update.app", teamID: app.teamID)
        XCTAssertFalse(BundleVerifier.matchesSelectedVersion(incoming, replacing: app, expectedVersion: incoming.version, expectedBuild: "200", buildIsAuthoritative: false))
        XCTAssertTrue(BundleVerifier.matchesSelectedVersion(incoming, replacing: app, expectedVersion: incoming.version, expectedBuild: "200", buildIsAuthoritative: false, allowPrerelease: true))
        XCTAssertFalse(BundleVerifier.matchesSelectedVersion(incoming, replacing: app, expectedVersion: "2.0-beta.3", expectedBuild: "200", buildIsAuthoritative: false, allowPrerelease: true))
        let path = "/Applications/Fixture-update.app"
        XCTAssertThrowsError(try AdministratorInstallPlan(operation: .application, application: app, version: incoming.version, build: "200", artifactPath: path).validate())
        XCTAssertNoThrow(try AdministratorInstallPlan(operation: .application, application: app, version: incoming.version, build: "200", artifactPath: path, permitsPrerelease: true).validate())
    }
    func testUnattendedPolicyRequiresConsentClosedApplicationCompleteSourceAndArchiveProof() throws {
        var state = UnattendedUpdateState()
        let target = candidate
        func reason(_ value: UpdateCandidate = target, state: UnattendedUpdateState, channel: ReleaseChannel = .stable,
                    ignored: Set<String> = [], policy: UpdatePolicy = .init(), running: Bool = false, writable: Bool = true,
                    status: SourceStatus = .updates) -> UnattendedUpdatePolicy.Deferral? {
            UnattendedUpdatePolicy.deferral(app: app, candidate: value, result: .init(appID: app.id, candidates: [value], note: "", status: status),
                state: state, channel: channel, ignored: ignored, updatePolicy: policy, running: running, writable: writable)
        }
        XCTAssertEqual(reason(state: state), .disabled)
        state.enabled = true; XCTAssertEqual(reason(state: state), .notGranted)
        state.grants = [try .init(application: app, channel: .stable)]
        XCTAssertNil(reason(state: state))
        XCTAssertEqual(reason(state: state, running: true), .running)
        XCTAssertEqual(reason(state: state, writable: false), .authorization)
        XCTAssertEqual(reason(state: state, status: .partial), .incompleteSource)
        XCTAssertEqual(reason(state: state, ignored: [app.bundleID]), .ignored)
        var policy = UpdatePolicy(); policy.skipped.insert(UpdatePolicy.key(target, app: app))
        XCTAssertEqual(reason(state: state, policy: policy), .policy)
        var pkg = target; pkg.download = .init(url: URL(string: "https://example.com/app.pkg")!, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(reason(pkg, state: state), .unverified)
        var noProof = target; noProof.download = .init(url: URL(string: "https://example.com/app.dmg")!)
        XCTAssertEqual(reason(noProof, state: state), .unverified)
        var beta = target; beta.releaseChannel = .beta
        XCTAssertEqual(reason(beta, state: state), .channel)
        state.grants = [try .init(application: app, channel: .beta)]
        XCTAssertNil(reason(beta, state: state, channel: .beta))
        XCTAssertEqual(reason(beta, state: state), .notGranted)
        let store = InstalledApp(name: app.name, bundleID: app.bundleID, version: app.version, path: app.path, teamID: app.teamID, isAppStore: true)
        XCTAssertThrowsError(try UnattendedGrant(application: store, channel: .stable))
    }
    func testInterruptedAttemptsRetainCooldownAndOnlyTheirOwnCommitCanPass() throws {
        var state = UnattendedUpdateState(); state.enabled = true
        state.grants = [try .init(application: app, channel: .stable)]
        let target = candidate, record = UnattendedUpdateRecord(app: app, candidate: candidate, channel: .stable)
        state.record(record); state.recoverInterrupted()
        XCTAssertEqual(state.history[0].phase, .interrupted)
        let result = SourceResult(appID: app.id, candidates: [target], note: "", status: .updates)
        XCTAssertEqual(UnattendedUpdatePolicy.deferral(app: app, candidate: target, result: result, state: state, channel: .stable,
            ignored: [], updatePolicy: .init(), running: false, writable: true), .cooldown)
        XCTAssertNil(UnattendedUpdatePolicy.deferral(app: app, candidate: target, result: result, state: state, channel: .stable,
            ignored: [], updatePolicy: .init(), running: false, writable: true, currentAttempt: record.id))
        let renamed = InstalledApp(name: app.name, bundleID: app.bundleID, version: app.version, path: "/Applications/Renamed.app", teamID: app.teamID)
        XCTAssertNil(state.grant(for: renamed, channel: .stable))
    }
    func testNativeRefreshHelperUsesReadOnlyModeAndRejectsDeniedOrStaleReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "helper")
        func helper(_ json: Data) throws {
            let text = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
            try Data("#!/bin/sh\n[ \"$1\" = --refresh-updates ] || exit 4\nprintf '%s' '\(text)'\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try helper(JSONEncoder().encode(StoreUpdateAvailability.FailureMessage(.notEntitled)))
        do { _ = try await StoreUpdateAvailability.query(using: file); XCTFail("Denied refresh was accepted") }
        catch { XCTAssertEqual(error as? StoreUpdateAvailability.RefreshFailure, .notEntitled); XCTAssertEqual(DiagnosticIssue(error).code, 505) }
        try helper(JSONEncoder().encode(StoreUpdateAvailability(offers: [], refreshedAt: Date().addingTimeInterval(-300))))
        do { _ = try await StoreUpdateAvailability.query(using: file); XCTFail("Stale refresh was accepted") } catch { }
        try helper(JSONEncoder().encode(StoreUpdateAvailability(offers: [], refreshedAt: Date())))
        let result = try await StoreUpdateAvailability.query(using: file)
        XCTAssertTrue(result.offers.isEmpty); XCTAssertNotNil(result.refreshedAt)
    }
}
