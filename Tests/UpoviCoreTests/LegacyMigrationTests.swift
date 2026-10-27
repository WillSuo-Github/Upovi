import XCTest
@testable import UpoviCore

final class LegacyMigrationTests: XCTestCase {
    private func old(version: String = "3.5.0", build: String = "2024.01.11", bundle: String = "com.caldis.Mos", team: String? = nil, store: Bool = false) -> InstalledApp {
        .init(name: "Mos", bundleID: bundle, version: version, build: build, path: "/Applications/Upovi Mos Fixture.app", teamID: team, isAppStore: store)
    }
    private func current(version: String = "4.2.1", build: String = "20260531.1", team: String? = "N7Z52F27XK") -> InstalledApp {
        .init(name: "Mos", bundleID: "com.caldis.Mos", version: version, build: build, path: old().path, teamID: team)
    }
    func testOnlyReviewedLegacyIdentityCanMigrateWithoutATeam() {
        XCTAssertEqual(ApplicationSourceCatalog.replacementTeam(for: old()), "N7Z52F27XK")
        for unsupported in [old(version: "3.4.0"), old(build: "unknown"), old(bundle: "com.lookalike.Mos"), old(store: true)] {
            XCTAssertNil(ApplicationSourceCatalog.legacyMigration(for: unsupported))
            XCTAssertNil(ApplicationSourceCatalog.replacementTeam(for: unsupported))
        }
        XCTAssertNil(ApplicationSourceCatalog.legacyMigration(for: old(team: "OTHERTEAM1")))
        XCTAssertEqual(ApplicationSourceCatalog.replacementTeam(for: old(team: "OTHERTEAM1")), "OTHERTEAM1")
    }
    func testBulkAvailabilityDoesNotAdmitOtherUnknownDevelopers() {
        let candidate = UpdateCandidate(version: "4.2.1", source: "Homebrew", isCommunity: false, url: nil,
            download: .init(url: URL(string: "https://github.com/Caldis/Mos/releases/download/4.2.1/Mos.zip")!, sha256: String(repeating: "a", count: 64)))
        for (app, expected) in [(old(), true), (old(build: "unknown"), false), (old(bundle: "com.lookalike.Mos"), false)] {
            let result = SourceResult(appID: app.id, candidates: [candidate], note: "Fixture", status: .updates)
            XCTAssertEqual(BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first?.canInstall, expected)
        }
    }
    func testMetadataAloneCannotAttestALegacyBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-legacy-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: root.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "com.caldis.Mos", "CFBundleExecutable": "Mos", "CFBundleShortVersionString": "3.5.0", "CFBundleVersion": "2024.01.11"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appending(path: "Contents/Info.plist"))
        try Data("forged executable".utf8).write(to: root.appending(path: "Contents/MacOS/Mos"))
        XCTAssertThrowsError(try BundleVerifier.checkSignature(root, like: old()))
        XCTAssertThrowsError(try BundleVerifier.checkDeveloperIDSignature(root, like: old()))
    }
    func testAdministratorMigrationPermitsOnlyDirectAppReplacement() {
        XCTAssertNoThrow(try AdministratorInstallPlan(operation: .application, application: old(), version: "4.2.1", build: "20260531.1", artifactPath: "/nonexistent/Prepared.app").validate())
        XCTAssertThrowsError(try AdministratorInstallPlan(operation: .package, application: old(), version: "4.2.1", artifactPath: "/nonexistent/Update.pkg", sha256: String(repeating: "a", count: 64)).validate())
        XCTAssertThrowsError(try AdministratorInstallPlan(operation: .application, application: old(build: "unknown"), version: "4.2.1", artifactPath: "/nonexistent/Prepared.app").validate())
    }
    func testRecoveryAcceptsThePinnedSuccessorAndRejectsExternalChanges() {
        XCTAssertTrue(AdministratorRecoveryPolicy.permits(current: old(), original: old(), selectedVersion: "4.2.1", selectedBuild: "20260531.1"))
        XCTAssertTrue(AdministratorRecoveryPolicy.permits(current: current(), original: old(), selectedVersion: "4.2.1", selectedBuild: "20260531.1"))
        for changed in [current(team: nil), current(team: "OTHERTEAM1"), current(version: "4.3.0"), current(build: "9999")] {
            XCTAssertFalse(AdministratorRecoveryPolicy.permits(current: changed, original: old(), selectedVersion: "4.2.1", selectedBuild: "20260531.1"))
        }
        XCTAssertFalse(AdministratorRecoveryPolicy.permits(current: current(), original: old(build: "unknown"), selectedVersion: "4.2.1", selectedBuild: "20260531.1"))
    }
    func testProtectedBackupCleanupTracksBothSidesOfTheMigration() {
        let plan = AdministratorInstallPlan(operation: .application, application: old(), version: "4.2.1", build: "20260531.1", artifactPath: "/nonexistent/Prepared.app")
        var installed = AdministratorInstallAttempt(plan: plan, state: "installed")
        installed.installedApplication = current()
        XCTAssertTrue(AdministratorBackupCleaner.canDiscard(installed, current: current()))
        XCTAssertFalse(AdministratorBackupCleaner.canDiscard(installed, current: current(team: "OTHERTEAM1")))
        installed.state = "restored"
        XCTAssertTrue(AdministratorBackupCleaner.canDiscard(installed, current: old()))
        XCTAssertFalse(AdministratorBackupCleaner.canDiscard(installed, current: current()))
    }
}
