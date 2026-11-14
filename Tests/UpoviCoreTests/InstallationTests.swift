import XCTest
import CryptoKit
@testable import UpoviCore

final class InstallationTests: XCTestCase {
    private func fixture(_ root: URL, name: String, version: String) throws -> InstalledApp {
        let app = root.appending(path: name + ".app"), contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "app.upovi.synthetic.installation", "CFBundleName": "Fixture", "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        return try XCTUnwrap(AppScanner.read(app))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func installedFixture() throws -> (URL, BundleTransaction, InstallationReceipt) {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        let transaction = BundleTransaction(journalDirectory: root.appending(path: "Journal"), validate: { _ in })
        let receipt = try transaction.commit(prepared: URL(fileURLWithPath: update.path), replacing: app, newVersion: "2.0", newBuild: "2.0")
        return (root, transaction, receipt)
    }
    func testBackupCleanupRecyclesOnlyTheRecordedBackupAndRetainsLiveApp() throws {
        let (root, transaction, receipt) = try installedFixture()
        let recycled = root.appending(path: "Recycled.app")
        let result = try transaction.discardBackup(receipt) { try FileManager.default.moveItem(at: $0, to: recycled) }
        XCTAssertEqual(result.state, .backupDiscarded)
        XCTAssertEqual(AppScanner.read(recycled)?.version, "1.0")
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: receipt.application.path))?.version, "2.0")
        XCTAssertThrowsError(try transaction.discardBackup(receipt) { _ in XCTFail("Already discarded") })
    }
    func testFailedRecyclingPreservesBackupAndJournalForRecovery() throws {
        let (_, transaction, receipt) = try installedFixture()
        XCTAssertThrowsError(try transaction.discardBackup(receipt) { _ in throw PeerError.invalid("Injected recycle failure") })
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: receipt.backupPath))?.version, "1.0")
        XCTAssertEqual(try transaction.restore(receipt).state, .restored)
    }
    func testRestoredInstallationRetainsAndCanRecycleDisplacedNewVersion() throws {
        let (root, transaction, receipt) = try installedFixture()
        let restored = try transaction.restore(receipt)
        let retainedPath = try XCTUnwrap(restored.retainedPath)
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: retainedPath))?.version, "2.0")
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: restored.application.path))?.version, "1.0")
        let result = try transaction.discardBackup(restored) { try FileManager.default.moveItem(at: $0, to: root.appending(path: "Recycled.app")) }
        XCTAssertEqual(result.state, .backupDiscarded)
        XCTAssertNil(result.retainedPath)
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: restored.application.path))?.version, "1.0")
    }
    func testBackupCleanupRejectsMissingOrExternallyChangedReplacement() throws {
        let (root, transaction, receipt) = try installedFixture()
        try FileManager.default.removeItem(atPath: receipt.application.path)
        XCTAssertThrowsError(try transaction.discardBackup(receipt) { _ in XCTFail("Missing replacement") })
        _ = try fixture(root, name: "Installed", version: "3.0")
        XCTAssertThrowsError(try transaction.discardBackup(receipt) { _ in XCTFail("Changed replacement") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupPath))
    }
    func testBackupCleanupRejectsUnrecordedPathsAndInterruptedTransactions() throws {
        let (_, transaction, receipt) = try installedFixture()
        let forged = InstallationReceipt(id: receipt.id, date: receipt.date, application: receipt.application,
            newVersion: receipt.newVersion, newBuild: receipt.newBuild, backupPath: receipt.application.path,
            incomingPath: receipt.incomingPath, state: .installed)
        XCTAssertThrowsError(try transaction.discardBackup(forged) { _ in XCTFail("Forged path") })
        var interrupted = receipt; interrupted.state = .backedUp
        XCTAssertThrowsError(try transaction.discardBackup(interrupted) { _ in XCTFail("Recovery material") })
    }
    func testBackupCleanupRejectsSymlinkReplacement() throws {
        let (root, transaction, receipt) = try installedFixture()
        let moved = root.appending(path: "Moved.app")
        try FileManager.default.moveItem(atPath: receipt.backupPath, toPath: moved.path)
        try FileManager.default.createSymbolicLink(atPath: receipt.backupPath, withDestinationPath: moved.path)
        XCTAssertThrowsError(try transaction.discardBackup(receipt) { _ in XCTFail("Linked backup") })
        XCTAssertEqual(AppScanner.read(moved)?.version, "1.0")
    }
    func testInstallationAndRestoreRetainOriginalBundle() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        let transaction = BundleTransaction(journalDirectory: root.appending(path: "Journal"), validate: { url in
            guard AppScanner.read(url)?.version == "2.0" else { throw PeerError.invalid("Invalid fixture version") }
        })
        let receipt = try transaction.commit(prepared: URL(fileURLWithPath: update.path), replacing: app, newVersion: "2.0", newBuild: "2.0")
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: app.path))?.version, "2.0")
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: receipt.backupPath))?.version, "1.0")
        let restored = try transaction.restore(receipt)
        XCTAssertEqual(restored.state, .restored)
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: app.path))?.version, "1.0")
    }
    func testFailureAfterBackupAutomaticallyRestoresOriginal() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        let transaction = BundleTransaction(journalDirectory: root.appending(path: "Journal"), validate: { _ in }, afterBackup: { throw PeerError.invalid("Injected failure") })
        XCTAssertThrowsError(try transaction.commit(prepared: URL(fileURLWithPath: update.path), replacing: app, newVersion: "2.0", newBuild: "2.0"))
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: app.path))?.version, "1.0")
    }
    func testConcurrentExternalUpdateStopsReplacementBeforeWritingAReceipt() throws {
        let root = try directory(), old = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        _ = try fixture(root, name: "Installed", version: "3.0")
        let journal = root.appending(path: "Journal")
        let transaction = BundleTransaction(journalDirectory: journal, validate: { _ in XCTFail("A changed original must not enter replacement") })
        XCTAssertThrowsError(try transaction.commit(prepared: URL(fileURLWithPath: update.path), replacing: old, newVersion: "2.0", newBuild: "2.0")) {
            XCTAssertTrue($0 is InstalledApplicationChanged)
        }
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: old.path))?.version, "3.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let target = UpdateCandidate(version: "2.0", source: "Fixture", isCommunity: false, url: nil)
        XCTAssertFalse(try BundleVerifier.selectedUpdateIsInstalled(old, candidate: target), "An unsigned newer bundle cannot become a successful no-op")
    }
    func testRestoreDoesNotOverwriteAnExternalUpdate() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        let transaction = BundleTransaction(journalDirectory: root.appending(path: "Journal"), validate: { _ in })
        let receipt = try transaction.commit(prepared: URL(fileURLWithPath: update.path), replacing: app, newVersion: "2.0", newBuild: "2.0")
        try FileManager.default.removeItem(atPath: app.path)
        _ = try fixture(root, name: "Installed", version: "3.0")
        XCTAssertThrowsError(try transaction.restore(receipt))
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: app.path))?.version, "3.0")
    }
    func testCompletedBackupArchiveIsInertAndRestoresVerifiedOldVersion() throws {
        let (root, transaction, receipt) = try installedFixture()
        let archived = try transaction.archiveRetainedCopy(receipt)
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(archived.retainedPath)).pathExtension, "zip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.backupPath))
        XCTAssertTrue(AppScanner.scan(roots: [root]).allSatisfy { !$0.path.contains("upovi-recovery") })
        XCTAssertEqual(try transaction.restore(archived).state, .restored)
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: receipt.application.path))?.version, "1.0")
    }
    func testCorruptedArchiveCannotReplaceLiveApplication() throws {
        let (_, transaction, receipt) = try installedFixture()
        let archived = try transaction.archiveRetainedCopy(receipt)
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: try XCTUnwrap(archived.retainedPath)))
        XCTAssertThrowsError(try transaction.restore(archived))
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: receipt.application.path))?.version, "2.0")
    }
    func testArchiveMigrationCanResumeAfterJournalPublicationBeforeRawRemoval() throws {
        let (_, transaction, receipt) = try installedFixture()
        let copy = URL(fileURLWithPath: receipt.backupPath).deletingLastPathComponent().appending(path: "Saved.app")
        try FileManager.default.copyItem(atPath: receipt.backupPath, toPath: copy.path)
        let archived = try transaction.archiveRetainedCopy(receipt)
        try FileManager.default.moveItem(atPath: copy.path, toPath: receipt.backupPath)
        _ = try transaction.archiveRetainedCopy(archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(archived.retainedPath)))
    }
    func testMaintenanceExpiresCompletedBackupsEvenAfterSignedLaterUpdate() throws {
        let (root, transaction, receipt) = try installedFixture()
        _ = try fixture(root, name: "Installed", version: "3.0")
        let report = transaction.maintain([receipt], now: receipt.date.addingTimeInterval(8 * 86400), isRunning: { _ in false }, verifyCurrent: { _ in })
        XCTAssertEqual(report.discarded, 1); XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.backupPath))
        XCTAssertEqual(AppScanner.read(URL(fileURLWithPath: receipt.application.path))?.version, "3.0")
    }
    func testMaintenanceNeverExpiresInterruptedOrRunningRecoveryCopies() throws {
        let (_, transaction, receipt) = try installedFixture()
        for state in [InstallationReceipt.State.prepared, .backedUp, .failed] {
            var interrupted = receipt; interrupted.state = state; try transaction.write(interrupted)
            let report = transaction.maintain([interrupted], now: receipt.date.addingTimeInterval(100 * 86400), isRunning: { _ in false }, verifyCurrent: { _ in XCTFail("Interrupted copy") })
            XCTAssertEqual(report.protected, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupPath))
        }
        try transaction.write(receipt)
        let report = transaction.maintain([receipt], now: receipt.date.addingTimeInterval(100 * 86400), isRunning: { _ in true }, verifyCurrent: { _ in XCTFail("Running copy") })
        XCTAssertEqual(report.protected, 1)
    }
    func testMaintenancePreservesBackupsOnSignatureFailureAndMissingLiveApp() throws {
        let (_, transaction, receipt) = try installedFixture()
        let now = receipt.date.addingTimeInterval(8 * 86400)
        var report = transaction.maintain([receipt], now: now, isRunning: { _ in false }, verifyCurrent: { _ in throw PeerError.invalid("Injected signature failure") })
        XCTAssertEqual(report.failed, 0); XCTAssertEqual(report.protected, 1)
        let archived = try JSONDecoder().decode(InstallationReceipt.self, from: Data(contentsOf: transaction.journalDirectory.appending(path: receipt.id + ".json")))
        try FileManager.default.removeItem(atPath: receipt.application.path)
        report = transaction.maintain([archived], now: now, isRunning: { _ in false }, verifyCurrent: { _ in XCTFail("Missing app") })
        XCTAssertEqual(report.failed, 0); XCTAssertEqual(report.protected, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(archived.retainedPath)))
    }
    func testMaintenanceRetainsOnlyLatestCompletedBackupForOneWeek() throws {
        let (root, transaction, first) = try installedFixture()
        let current = try XCTUnwrap(AppScanner.read(URL(fileURLWithPath: first.application.path)))
        let incoming = try fixture(root, name: "Third", version: "3.0")
        let second = try transaction.commit(prepared: URL(fileURLWithPath: incoming.path), replacing: current, newVersion: "3.0", newBuild: "3.0")
        let report = transaction.maintain([first, second], now: second.date, isRunning: { _ in false }, verifyCurrent: { _ in })
        XCTAssertEqual(report.discarded, 1); XCTAssertEqual(report.archived, 1); XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.archiveURL(second, restored: false).path))
    }
    func testLegacyCompletedBackupMigratesWithoutChangingOriginalReceiptIdentity() throws {
        let (root, transaction, receipt) = try installedFixture()
        let legacy = root.appending(path: ".upovi-backup-\(receipt.id).app")
        try FileManager.default.moveItem(atPath: receipt.backupPath, toPath: legacy.path)
        let migrated = InstallationReceipt(id: receipt.id, date: receipt.date, application: receipt.application, newVersion: receipt.newVersion,
            newBuild: receipt.newBuild, backupPath: legacy.path, incomingPath: receipt.incomingPath, state: .installed)
        try transaction.write(migrated)
        let archived = try transaction.archiveRetainedCopy(migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(archived.backupPath, legacy.path)
        XCTAssertEqual(try transaction.restore(archived).state, .restored)
    }

    func testUnsignedApplicationsCannotPassProductionVerifier() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        XCTAssertThrowsError(try BundleVerifier.validate(URL(fileURLWithPath: update.path), replacing: app, expectedVersion: "2.0", expectedBuild: "2.0"))
    }
    func testSparklePayloadUsesExactAuthoritativeBuildDespiteIncorrectDisplayLabel() {
        let old = InstalledApp(name: "PlayCover", bundleID: "io.playcover.PlayCover", version: "3.1.0", build: "856", path: "/fixture/old.app")
        func payload(_ version: String = "3.1.0", _ build: String = "1633") -> InstalledApp {
            .init(name: old.name, bundleID: old.bundleID, version: version, build: build, path: "/fixture/incoming.app")
        }
        XCTAssertTrue(BundleVerifier.matchesSelectedVersion(payload(), replacing: old, expectedVersion: "4.0.0", expectedBuild: "1633", buildIsAuthoritative: true))
        XCTAssertFalse(BundleVerifier.matchesSelectedVersion(payload(), replacing: old, expectedVersion: "4.0.0", expectedBuild: "1633", buildIsAuthoritative: false))
        for build in ["", "856", "1632", "1634"] {
            XCTAssertFalse(BundleVerifier.matchesSelectedVersion(payload("4.0.0", build), replacing: old, expectedVersion: "4.0.0", expectedBuild: "1633", buildIsAuthoritative: true))
        }
        XCTAssertFalse(BundleVerifier.matchesSelectedVersion(payload(), replacing: payload(), expectedVersion: "4.0.0", expectedBuild: "1633", buildIsAuthoritative: true))
        XCTAssertFalse(BundleVerifier.matchesSelectedVersion(payload(), replacing: old, expectedVersion: "4.0.0", expectedBuild: "", buildIsAuthoritative: true))
    }
    func testArchiveChecksumMustMatch() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let archive = root.appending(path: "file.zip"), data = Data("fixture".utf8)
        try data.write(to: archive)
        let valid = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try BundleVerifier.verifyArchive(archive, descriptor: .init(url: URL(string: "https://example.com/a.zip")!, sha256: valid), app: app))
        XCTAssertThrowsError(try BundleVerifier.verifyArchive(archive, descriptor: .init(url: URL(string: "https://example.com/a.zip")!, sha256: String(repeating: "0", count: 64)), app: app))
    }
    func testJournalLockAllowsParallelInstallsButExcludesMaintenanceAcrossInstances() throws {
        let root = try directory()
        let first = try XCTUnwrap(InstallationJournalLock.acquire(in: root, exclusive: false))
        let second = try XCTUnwrap(InstallationJournalLock.acquire(in: root, exclusive: false))
        XCTAssertNil(try InstallationJournalLock.acquire(in: root, exclusive: true))
        first.unlock(); second.unlock()
        let maintenance = try XCTUnwrap(InstallationJournalLock.acquire(in: root, exclusive: true))
        XCTAssertNil(try InstallationJournalLock.acquire(in: root, exclusive: false))
        XCTAssertNil(try InstallationJournalLock.acquire(in: root, exclusive: true))
        maintenance.unlock()
    }
    func testJournalLockRefusesLinkedFiles() throws {
        let root = try directory(), external = root.appending(path: "External")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "maintenance.lock"), withDestinationURL: external)
        XCTAssertThrowsError(try InstallationJournalLock.acquire(in: root, exclusive: true))
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
    }

    func testRecoveryArchiveRetainsContainedParentLinksWithoutRelaxingDownloads() throws {
        let (root, transaction, receipt) = try installedFixture()
        let backup = URL(fileURLWithPath: receipt.backupPath)
        let directory = backup.appending(path: "Contents/Helpers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: directory.appending(path: "InfoLink").path, withDestinationPath: "../Info.plist")
        let archived = try transaction.archiveRetainedCopy(receipt)
        let archive = URL(fileURLWithPath: try XCTUnwrap(archived.retainedPath))
        XCTAssertThrowsError(try ArchiveExtractor.extractZIP(archive, to: root.appending(path: "DownloadExtraction")))
        let restored = try transaction.restore(archived)
        let link = URL(fileURLWithPath: restored.application.path).appending(path: "Contents/Helpers/InfoLink")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../Info.plist")
    }
    func testRecoveryArchiveRejectsLinksEscapingTheApplicationRoot() throws {
        let (_, transaction, receipt) = try installedFixture()
        let backup = URL(fileURLWithPath: receipt.backupPath)
        try FileManager.default.createSymbolicLink(atPath: backup.appending(path: "Escape").path, withDestinationPath: "../External")
        XCTAssertThrowsError(try transaction.archiveRetainedCopy(receipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupPath))
    }

}
