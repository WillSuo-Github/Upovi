import XCTest
@testable import UpoviCore

final class AdministratorInstallationTests: XCTestCase {
    func testSpacePreflightKeepsTheProtectedBackupPolicyAndReportsActionableNumbers() throws {
        XCTAssertEqual(AdministratorInstallationSpace.requiredBytes(applicationBytes: 100_000_000), 6_000_000_000)
        XCTAssertEqual(AdministratorInstallationSpace.requiredBytes(applicationBytes: 2_000_000_000), 8_000_000_000)
        XCTAssertEqual(AdministratorInstallationSpace.requiredBytes(applicationBytes: Int64.max), Int64.max)
        XCTAssertThrowsError(try AdministratorInstallationSpace.check(required: 6_000_000_000, available: 5_000_000_000)) { error in
            let space = error as? InstallationSpaceError
            XCTAssertEqual(space?.required, 6_000_000_000); XCTAssertEqual(space?.available, 5_000_000_000)
            XCTAssertNotNil(AdministratorInstallationSpace.message(for: error))
            let wrapped = PeerError.unavailable("Authorized installer failed (1): " + error.localizedDescription)
            XCTAssertEqual(AdministratorInstallationSpace.message(for: wrapped), space?.userMessage)
        }
        XCTAssertThrowsError(try AdministratorInstallationSpace.check(required: 6_000_000_000, available: 6_000_000_000))
        XCTAssertNoThrow(try AdministratorInstallationSpace.check(required: 6_000_000_000, available: 6_000_000_001))
        XCTAssertNil(AdministratorInstallationSpace.message(for: PeerError.invalid("Unrelated signature failure")))
    }
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

extension AdministratorInstallationTests {
    func testBatchUsesOneAuthorizationAndKeepsSignedHelperChecksForBothChannels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-batch-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = [
            try AdministratorAuthorization.command(helper: root.appending(path: "Direct ' helper"), plan: root.appending(path: "Direct.json"), hostTeam: "SYNTHETIC1"),
            try AppStoreUpdatePlan.authorizationCommand(helper: root.appending(path: "Store"), bridge: root.appending(path: "Bridge"), plan: root.appending(path: "Store.json"), hostTeam: "SYNTHETIC1")
        ]
        let script = AdministratorAuthorization.script(command: AdministratorAuthorization.batchCommand(commands, stopFile: root.appending(path: "stop")))
        XCTAssertEqual(script.components(separatedBy: "with administrator privileges").count - 1, 1)
        for identifier in ["app.upovi.Installer", "app.upovi.StoreInstaller", "app.upovi.StoreBridge"] { XCTAssertTrue(script.contains(identifier)) }
        let source = root.appending(path: "Batch.applescript"), compiled = root.appending(path: "Batch.scpt")
        try script.write(to: source, atomically: true, encoding: .utf8)
        _ = try await ProcessCommand().run("/usr/bin/osacompile", ["-o", compiled.path, source.path])
    }

    func testBatchIsolatesFailuresAndRoundTripsQuotedMultilineOutput() async throws {
        let text = "line one: 'quoted' $(exit 88)\n第二行"
        let commands = ["printf '%s' " + AdministratorAuthorization.shellQuote(text), "printf 'failure' >&2; exit 23", "printf 'last'"]
        let command = AdministratorAuthorization.batchCommand(commands, stopFile: URL(fileURLWithPath: "/nonexistent/Upovi-stop"))
        let output = try await ProcessCommand().run("/bin/sh", ["-c", command])
        let results = try AdministratorAuthorization.batchResults(output, count: 3)
        XCTAssertEqual(results.map(\.status), [0, 23, 0])
        XCTAssertEqual(String(decoding: results[0].output, as: UTF8.self), text)
        XCTAssertEqual(String(decoding: results[1].output, as: UTF8.self), "failure")
        XCTAssertEqual(String(decoding: results[2].output, as: UTF8.self), "last")
    }

    func testBatchStopFinishesCurrentCommandAndSkipsLaterCommands() async throws {
        let stop = FileManager.default.temporaryDirectory.appending(path: "Upovi-batch-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stop) }
        let command = AdministratorAuthorization.batchCommand([
            "printf 'committed'; /usr/bin/touch " + AdministratorAuthorization.shellQuote(stop.path),
            "printf 'must not run'; exit 99"
        ], stopFile: stop)
        let output = try await ProcessCommand().run("/bin/sh", ["-c", command])
        let results = try AdministratorAuthorization.batchResults(output, count: 2)
        XCTAssertEqual(results.map(\.status), [0, -1])
        XCTAssertEqual(String(decoding: results[0].output, as: UTF8.self), "committed")
        XCTAssertTrue(results[1].output.isEmpty)
    }

    func testBatchRejectsMissingDuplicateAndCorruptResults() {
        for output in ["0:0:", "0:0:\n0:0:", "0:0:@@\n1:0:", "0:999:\n1:0:"] {
            XCTAssertThrowsError(try AdministratorAuthorization.batchResults(Data(output.utf8), count: 2))
        }
    }
}

extension AdministratorInstallationTests {
    private func sessionFixture(store: Bool = false) throws -> (AdministratorInstallSession, BulkUpdateItem) {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-session-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let candidate = UpdateCandidate(version: "2.0", build: "2", source: "Fixture", isCommunity: false, url: nil,
            download: store ? nil : .init(url: URL(string: "https://example.invalid/app.zip")!, sha256: String(repeating: "a", count: 64)), appStoreID: store ? 123 : nil)
        let item = BulkUpdateItem(application: app(appStore: store), candidate: candidate, manualReason: nil)
        return (AdministratorInstallSession(items: [item], requests: directory, hostTeam: "SYNTHETIC1"), item)
    }
    func testSessionOnlyAcceptsConfirmedApplicationVersionAndInstallOperation() throws {
        let (session, item) = try sessionFixture()
        try session.validate()
        func request(version: String = "2.0", build: String = "2", operation: AdministratorInstallPlan.Operation = .application,
                     application: InstalledApp? = nil, beta: Bool = false) -> AdministratorInstallSession.Request {
            .application(.init(operation: operation, application: application ?? item.application, version: version, build: build,
                artifactPath: "/nonexistent/Prepared.app", permitsPrerelease: beta))
        }
        XCTAssertNoThrow(try session.validate(request(), index: 0))
        XCTAssertThrowsError(try session.validate(request(), index: 1))
        XCTAssertThrowsError(try session.validate(request(version: "3.0"), index: 0))
        XCTAssertThrowsError(try session.validate(request(build: "3"), index: 0))
        XCTAssertThrowsError(try session.validate(request(operation: .inspect), index: 0))
        XCTAssertThrowsError(try session.validate(request(operation: .restore), index: 0))
        XCTAssertThrowsError(try session.validate(request(beta: true), index: 0))
        XCTAssertThrowsError(try session.validate(request(application: app(path: "/Applications/Other.app")), index: 0))
    }
    func testStoreSessionPinsStoreIDUserAndReceiptRecovery() throws {
        let (session, item) = try sessionFixture(store: true)
        try session.validate()
        func request(storeID: UInt64 = 123, userID: UInt32? = nil, version: String = "2.0", recovery: StoreReceiptRecovery? = nil) -> AdministratorInstallSession.Request {
            .store(.init(application: item.application, storeID: storeID, version: version, userID: userID ?? session.userID, receiptRecovery: recovery))
        }
        XCTAssertNoThrow(try session.validate(request(), index: 0))
        XCTAssertThrowsError(try session.validate(request(storeID: 456), index: 0))
        XCTAssertThrowsError(try session.validate(request(userID: session.userID + 1), index: 0))
        XCTAssertThrowsError(try session.validate(request(version: "3.0"), index: 0))
        XCTAssertThrowsError(try session.validate(request(recovery: .init(transactionID: UUID(), path: "/private/var/folders/fixture/receipt")), index: 0))
    }
    func testSessionBootstrapFreezesSelectionAndVerifiesHelpersBeforeStarting() throws {
        let (session, _) = try sessionFixture(store: true)
        let command = try session.bootstrap(helper: URL(fileURLWithPath: "/fixture/UpoviInstaller"),
            storeHelper: URL(fileURLWithPath: "/fixture/UpoviStoreInstaller.app"), bridge: URL(fileURLWithPath: "/fixture/UpoviStoreBridge"))
        XCTAssertTrue(command.contains("/usr/bin/base64 -D > \"$work/session.json\""))
        XCTAssertTrue(command.contains("identifier \"app.upovi.Installer\""))
        XCTAssertTrue(command.contains("identifier \"app.upovi.StoreInstaller\""))
        XCTAssertTrue(command.contains("identifier \"app.upovi.StoreBridge\""))
        XCTAssertTrue(command.hasSuffix("\"$work/UpoviInstaller\" --session \"$work/session.json\" \"$work\""))
        XCTAssertFalse(command.contains("sudo"))
        _ = try JSONDecoder().decode(AdministratorInstallSession.self, from: JSONEncoder().encode(session))
    }
    func testSessionRequestReaderRejectsSymlinksDevicesAndOversizedInputs() throws {
        let (session, _) = try sessionFixture()
        let directory = open(session.requestsPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { close(directory) }
        let file = URL(fileURLWithPath: session.requestsPath).appending(path: "0.json")
        XCTAssertNil(try AdministratorInstallSession.readRequest(directory: directory, name: "0.json", owner: getuid()))
        try Data("fixture".utf8).write(to: file)
        XCTAssertEqual(try AdministratorInstallSession.readRequest(directory: directory, name: "0.json", owner: getuid()), Data("fixture".utf8))
        XCTAssertThrowsError(try AdministratorInstallSession.readRequest(directory: directory, name: "0.json", owner: getuid() + 1))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try AdministratorInstallSession.readRequest(directory: directory, name: "0.json", owner: getuid()))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try AdministratorInstallSession.readRequest(directory: directory, name: "0.json", owner: getuid()))
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0, count: 65537).write(to: file)
        XCTAssertThrowsError(try AdministratorInstallSession.readRequest(directory: directory, name: "0.json", owner: getuid()))
    }
}

extension AdministratorInstallationTests {
    func testPostInstallFinalizationFailurePreservesInstalledVersionAndRecoveryEvidence() throws {
        let original = app()
        let plan = AdministratorInstallPlan(operation: .package, application: original, version: "2.0", build: "2",
            artifactPath: "/nonexistent/Update.pkg", sha256: String(repeating: "a", count: 64))
        var attempt = AdministratorInstallAttempt(plan: plan, state: "finalizationPending")
        attempt.installedApplication = .init(name: original.name, bundleID: original.bundleID, version: "2.0", build: "2", path: original.path, teamID: original.teamID)
        attempt.finalizationFailure = AdministratorFinalizationError(POSIXError(.EPERM))
        let receipt = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: JSONEncoder().encode(attempt))
        XCTAssertEqual(receipt.state, "finalizationPending")
        XCTAssertEqual(receipt.installedApplication?.version, "2.0")
        XCTAssertEqual(receipt.finalizationFailure?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(receipt.finalizationFailure?.code, Int(EPERM))
        XCTAssertTrue(AdministratorBackupCleaner.canRestore(receipt.state))
        XCTAssertFalse(AdministratorBackupCleaner.canDiscard(receipt, current: receipt.installedApplication))
    }
}
