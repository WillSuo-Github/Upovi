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
    func testUnsignedApplicationsCannotPassProductionVerifier() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let update = try fixture(root, name: "Prepared", version: "2.0")
        XCTAssertThrowsError(try BundleVerifier.validate(URL(fileURLWithPath: update.path), replacing: app, expectedVersion: "2.0", expectedBuild: "2.0"))
    }
    func testArchiveChecksumMustMatch() throws {
        let root = try directory(), app = try fixture(root, name: "Installed", version: "1.0")
        let archive = root.appending(path: "file.zip"), data = Data("fixture".utf8)
        try data.write(to: archive)
        let valid = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try BundleVerifier.verifyArchive(archive, descriptor: .init(url: URL(string: "https://example.com/a.zip")!, sha256: valid), app: app))
        XCTAssertThrowsError(try BundleVerifier.verifyArchive(archive, descriptor: .init(url: URL(string: "https://example.com/a.zip")!, sha256: String(repeating: "0", count: 64)), app: app))
    }
}
