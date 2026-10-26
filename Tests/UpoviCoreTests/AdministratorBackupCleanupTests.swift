import XCTest
@testable import UpoviCore

final class AdministratorBackupCleanupTests: XCTestCase {
    private var original: InstalledApp { .init(name: "Fixture", bundleID: "app.synthetic.cleanup", version: "1.0", build: "1", path: "/Applications/Upovi Cleanup Fixture.app", teamID: "SYNTHETIC1") }
    private func current(_ version: String = "2.0", build: String = "2", team: String = "SYNTHETIC1") -> InstalledApp {
        .init(name: original.name, bundleID: original.bundleID, version: version, build: build, path: original.path, teamID: team)
    }
    private func fixture(state: String = "installed") throws -> (URL, AdministratorInstallAttempt) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-cleanup-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plan = AdministratorInstallPlan(operation: .application, application: original, version: "2.0", build: "2", artifactPath: "/nonexistent/Prepared.app")
        let job = root.appending(path: plan.id.uuidString)
        try FileManager.default.createDirectory(at: job.appending(path: "Original.app"), withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: job.appending(path: "Original.app/data"))
        try Data("journal".utf8).write(to: job.appending(path: "receipt.json"))
        return (job, .init(plan: plan, state: state))
    }
    func testOnlyCompletedMatchingApplicationsCanDiscardBackups() throws {
        let (_, value) = try fixture()
        XCTAssertTrue(AdministratorBackupCleaner.canDiscard(value, current: current()))
        for changed in [current("3.0"), current(build: "3"), current(team: "OTHERTEAM1")] {
            XCTAssertFalse(AdministratorBackupCleaner.canDiscard(value, current: changed))
        }
        XCTAssertFalse(AdministratorBackupCleaner.canDiscard(value, current: nil))
        for state in ["preparing", "backedUp", "installing", "failed", "awaitingAuthorization"] {
            var interrupted = value; interrupted.state = state
            XCTAssertFalse(AdministratorBackupCleaner.canDiscard(interrupted, current: current()))
        }
        var restored = value; restored.state = "restored"
        XCTAssertTrue(AdministratorBackupCleaner.canDiscard(restored, current: original))
        XCTAssertFalse(AdministratorBackupCleaner.canDiscard(restored, current: current()))
    }
    func testCleanupRevokesRecoveryBeforeDeletionAndKeepsJournalAndOtherFiles() throws {
        let (job, value) = try fixture()
        try Data("log".utf8).write(to: job.appending(path: "installer.log"))
        try Data("unrelated".utf8).write(to: job.appending(path: "other.txt"))
        var durable = value
        let result = try AdministratorBackupCleaner.discard(value, in: job, current: current(), validateCurrent: { }, save: { durable = $0 }, remove: { url in
            XCTAssertEqual(durable.state, "backupDiscarded")
            XCTAssertEqual(durable.cleanupComplete, false)
            XCTAssertFalse(AdministratorBackupCleaner.canRestore(durable.state))
            try FileManager.default.removeItem(at: url)
        })
        XCTAssertEqual(result.cleanupComplete, true)
        XCTAssertEqual(result.backupBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appending(path: "Original.app").path))
        XCTAssertEqual(try String(contentsOf: job.appending(path: "receipt.json"), encoding: .utf8), "journal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appending(path: "installer.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appending(path: "other.txt").path))
    }
    func testFailedRevocationWriteDeletesNothing() throws {
        let (job, value) = try fixture()
        XCTAssertThrowsError(try AdministratorBackupCleaner.discard(value, in: job, current: current(), validateCurrent: { }, save: { _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appending(path: "Original.app/data").path))
    }
    func testInterruptedDeletionCanResumeWithoutRestoringRevokedRecovery() throws {
        let (job, value) = try fixture()
        var durable = value
        XCTAssertThrowsError(try AdministratorBackupCleaner.discard(value, in: job, current: current(), validateCurrent: { }, save: { durable = $0 }, remove: { _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertFalse(AdministratorBackupCleaner.canRestore(durable.state))
        XCTAssertEqual(durable.cleanupComplete, false)
        let result = try AdministratorBackupCleaner.discard(durable, in: job, current: nil, validateCurrent: { XCTFail("Revoked cleanup does not operate on a live application") }, save: { durable = $0 })
        XCTAssertEqual(result.cleanupComplete, true)
        XCTAssertFalse(AdministratorBackupCleaner.canDiscard(result, current: current()))
    }
    func testLinkedRetainedDataCannotDeleteItsExternalTarget() throws {
        let (job, value) = try fixture()
        let external = job.deletingLastPathComponent().appending(path: "external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: external.appending(path: "keep"))
        try FileManager.default.createSymbolicLink(at: job.appending(path: "Previous.app"), withDestinationURL: external)
        _ = try AdministratorBackupCleaner.discard(value, in: job, current: current(), validateCurrent: { }, save: { _ in })
        XCTAssertEqual(try String(contentsOf: external.appending(path: "keep"), encoding: .utf8), "keep")
    }
    func testWrongJobAndFailedSignatureCannotDeleteAnything() throws {
        let (job, value) = try fixture()
        XCTAssertThrowsError(try AdministratorBackupCleaner.discard(value, in: job.deletingLastPathComponent(), current: current(), validateCurrent: { }, save: { _ in }))
        XCTAssertThrowsError(try AdministratorBackupCleaner.discard(value, in: job, current: current(), validateCurrent: { throw PeerError.invalid("Signature mismatch") }, save: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appending(path: "Original.app/data").path))
    }
    func testReadAndCleanupPlansDoNotRequireInstallationArtifacts() throws {
        for operation in [AdministratorInstallPlan.Operation.inspect, .discardBackup] {
            XCTAssertNoThrow(try AdministratorInstallPlan(operation: operation, application: original, version: "2.0").validate())
        }
        let (_, value) = try fixture()
        let decoded = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.cleanupComplete)
        XCTAssertTrue(AdministratorBackupCleaner.canRestore(decoded.state))
    }
    func testCleanupRequestCannotBorrowAnotherTransactionsAuthorization() throws {
        let (_, stored) = try fixture()
        let request = AdministratorInstallPlan(id: stored.id, operation: .discardBackup, application: original, version: "2.0", build: "2")
        XCTAssertTrue(AdministratorBackupCleaner.requestMatches(request, stored: stored))
        let changed = AdministratorInstallPlan(id: stored.id, operation: .discardBackup, application: current(), version: "2.0", build: "2")
        XCTAssertFalse(AdministratorBackupCleaner.requestMatches(changed, stored: stored))
        let wrongVersion = AdministratorInstallPlan(id: stored.id, operation: .inspect, application: original, version: "3.0", build: "2")
        XCTAssertFalse(AdministratorBackupCleaner.requestMatches(wrongVersion, stored: stored))
    }
}
