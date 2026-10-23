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
