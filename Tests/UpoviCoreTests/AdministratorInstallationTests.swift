import XCTest
@testable import UpoviCore

final class AdministratorInstallationTests: XCTestCase {
    private func app(path: String = "/Applications/Upovi Synthetic.app", team: String? = "SYNTHETIC1", appStore: Bool = false) -> InstalledApp {
        .init(name: "Synthetic", bundleID: "app.upovi.synthetic.admin", version: "1.0", build: "1", path: path, teamID: team, isAppStore: appStore)
    }
    func testAdministratorDestinationsAndIdentityAreRestricted() {
        for path in ["/System/Applications/Target.app", "/Applications", "/Applications/Nested/Target.app", "/tmp/Target.app", "/Applications/../Target.app"] {
            XCTAssertThrowsError(try AdministratorInstallPlan(operation: .application, application: app(path: path), version: "2.0", artifactPath: "/nonexistent/Prepared.app").validate())
        }
        for value in [app(team: nil), app(team: "wrong"), app(appStore: true)] {
            XCTAssertThrowsError(try AdministratorInstallPlan(operation: .application, application: value, version: "2.0", artifactPath: "/nonexistent/Prepared.app").validate())
        }
        XCTAssertNoThrow(try AdministratorInstallPlan(operation: .application, application: app(), version: "2.0", artifactPath: "/nonexistent/Prepared.app").validate())
    }
    func testPackageRequiresHashNewVersionAndPackageExtension() {
        XCTAssertThrowsError(try AdministratorInstallPlan(operation: .package, application: app(), version: "2.0", artifactPath: "/nonexistent/Update.pkg").validate())
        XCTAssertThrowsError(try AdministratorInstallPlan(operation: .package, application: app(), version: "1.0", artifactPath: "/nonexistent/Update.pkg", sha256: String(repeating: "a", count: 64)).validate())
        XCTAssertThrowsError(try AdministratorInstallPlan(operation: .package, application: app(), version: "2.0", artifactPath: "/nonexistent/Update.zip", sha256: String(repeating: "a", count: 64)).validate())
        XCTAssertNoThrow(try AdministratorInstallPlan(operation: .package, application: app(), version: "2.0", artifactPath: "/nonexistent/Update.pkg", sha256: String(repeating: "a", count: 64)).validate())
    }
    func testOnlyFirstDeveloperIDInstallerCertificateCanSupplyTeam() {
        let valid = "Status: signed by a certificate trusted by macOS\n  1. Developer ID Installer: Synthetic Developer (SYNTHETIC1)\n  2. Developer ID Certification Authority\n"
        XCTAssertEqual(InstallerPackageVerifier.signerTeam(in: valid), "SYNTHETIC1")
        XCTAssertNil(InstallerPackageVerifier.signerTeam(in: valid.replacingOccurrences(of: "1. Developer", with: "2. Developer")))
        XCTAssertNil(InstallerPackageVerifier.signerTeam(in: valid.replacingOccurrences(of: "Installer:", with: "Application:")))
        XCTAssertNil(InstallerPackageVerifier.signerTeam(in: "Unsigned\n(SYNTHETIC1)"))
    }
    func testShellArgumentsCannotExecuteInjectedCommands() async throws {
        let dangerous = "a'b\"c; $(exit 42) `exit 43`\nnext"
        let output = try await ProcessCommand().run("/bin/sh", ["-c", "printf '%s' " + AdministratorAuthorization.shellQuote(dangerous)])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), dangerous)
        XCTAssertThrowsError(try AdministratorAuthorization.script(helper: URL(fileURLWithPath: "/a"), plan: URL(fileURLWithPath: "/b"), hostTeam: "bad; exit"))
    }
    func testAdministratorAttemptPersistsInterruptionAndRecoveryIdentity() throws {
        let plan = AdministratorInstallPlan(operation: .package, application: app(), version: "2.0", artifactPath: "/nonexistent/Update.pkg", sha256: String(repeating: "a", count: 64))
        let value = AdministratorInstallAttempt(plan: plan, state: "awaitingAuthorization")
        let decoded = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.id, plan.id); XCTAssertEqual(decoded.state, "awaitingAuthorization")
        XCTAssertEqual(decoded.plan.application, plan.application)
    }
    func testAuthorizationScriptCompilesWithoutExecutingAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-authorization-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try AdministratorAuthorization.script(helper: root.appending(path: "Helper ' quoted"), plan: root.appending(path: "Plan \" quoted.json"), hostTeam: "SYNTHETIC1")
        let source = root.appending(path: "Bootstrap.applescript"), compiled = root.appending(path: "Bootstrap.scpt")
        try script.write(to: source, atomically: true, encoding: .utf8)
        _ = try await ProcessCommand().run("/usr/bin/osacompile", ["-o", compiled.path, source.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiled.path))
    }
    func testAdministratorRecoveryRejectsExternalUpdatesAndWrongIdentities() {
        let original = app()
        func current(_ version: String, build: String = "2", team: String = "SYNTHETIC1", id: String = "app.upovi.synthetic.admin") -> InstalledApp {
            .init(name: "Synthetic", bundleID: id, version: version, build: build, path: original.path, teamID: team)
        }
        XCTAssertTrue(AdministratorRecoveryPolicy.permits(current: original, original: original, selectedVersion: "2.0", selectedBuild: "2"))
        XCTAssertTrue(AdministratorRecoveryPolicy.permits(current: current("2.0"), original: original, selectedVersion: "2.0", selectedBuild: "2"))
        XCTAssertFalse(AdministratorRecoveryPolicy.permits(current: current("3.0"), original: original, selectedVersion: "2.0", selectedBuild: "2"))
        XCTAssertFalse(AdministratorRecoveryPolicy.permits(current: current("2.0", build: "3"), original: original, selectedVersion: "2.0", selectedBuild: "2"))
        XCTAssertFalse(AdministratorRecoveryPolicy.permits(current: current("2.0", team: "OTHERTEAM1"), original: original, selectedVersion: "2.0", selectedBuild: "2"))
        XCTAssertFalse(AdministratorRecoveryPolicy.permits(current: current("2.0", id: "app.other"), original: original, selectedVersion: "2.0", selectedBuild: "2"))
    }
    func testFailedSystemCommandRetainsItsLocalDiagnosticLog() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "Upovi-command-log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            _ = try await ProcessCommand().run("/bin/sh", ["-c", "printf stdout; printf stderr >&2; exit 23"], outputFile: output)
            XCTFail("The system command must report its failure")
        } catch {
            let saved = try String(contentsOf: output, encoding: .utf8)
            XCTAssertTrue(saved.contains("stdout")); XCTAssertTrue(saved.contains("stderr"))
        }
    }
    func testDeveloperIDRequirementIsCompiledByTheSystemRequirementTool() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "Upovi-requirement-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: output) }
        let requirement = try AdministratorAuthorization.requirement(hostTeam: "SYNTHETIC1")
        _ = try await ProcessCommand().run("/usr/bin/csreq", ["-r", requirement, "-b", output.path])
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
    }
    func testProtectedTemporaryPathsUsePhysicalResolutionAndStillExposeSymlinks() throws {
        let directory = URL(fileURLWithPath: "/private/var/tmp").appending(path: "Upovi-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "plan.json"), link = directory.appending(path: "linked.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(try CanonicalFilePath.resolve(file), file.path)
        XCTAssertNotEqual(try CanonicalFilePath.resolve(link), link.path)
        XCTAssertEqual(try CanonicalFilePath.resolve(link), file.path)
    }
}
