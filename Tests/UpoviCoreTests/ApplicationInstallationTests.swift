import Darwin
import XCTest
@testable import UpoviCore

final class ApplicationInstallationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-finalization-\(UUID().uuidString)")
        let app = root.appending(path: "Fixture.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: app.appending(path: "Contents/MacOS/Fixture"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return app
    }
    private func mark(_ file: URL, name: String = "com.apple.quarantine") throws {
        let result = "0081;00000000;UpoviTest;fixture".withCString { setxattr(file.path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func hasMarker(_ file: URL, name: String = "com.apple.quarantine") -> Bool {
        getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
    func testFinalizationPreservesOtherMetadataAndDoesNotTraverseSymlinks() async throws {
        let app = try fixture(), binary = app.appending(path: "Contents/MacOS/Fixture")
        let outside = app.deletingLastPathComponent().appending(path: "Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let external = outside.appending(path: "External")
        try Data("external".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: app.appending(path: "LinkedDirectory"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: app.appending(path: "LinkedFile"), withDestinationURL: external)
        for file in [app, app.appending(path: "Contents"), binary, external, outside] { try mark(file) }
        try mark(binary, name: "org.upovi.finalization-test")
        try await ApplicationInstallation.finalize(app, validate: { _ in }, assess: { _ in })
        for file in [app, app.appending(path: "Contents"), binary] { XCTAssertFalse(hasMarker(file)) }
        XCTAssertTrue(hasMarker(binary, name: "org.upovi.finalization-test"))
        XCTAssertTrue(hasMarker(external)); XCTAssertTrue(hasMarker(outside))
        try ApplicationInstallation.verifyFinalized(app)
        try await ApplicationInstallation.finalize(app, validate: { _ in }, assess: { _ in })
    }
    func testRejectedGatekeeperAssessmentLeavesQuarantineUntouched() async throws {
        let app = try fixture(), binary = app.appending(path: "Contents/MacOS/Fixture")
        try mark(app); try mark(binary)
        do {
            try await ApplicationInstallation.finalize(app, validate: { _ in }, assess: { _ in throw PeerError.invalid("Gatekeeper rejected") })
            XCTFail("Rejected downloads must remain isolated")
        } catch { }
        XCTAssertTrue(hasMarker(app)); XCTAssertTrue(hasMarker(binary))
    }
    func testIdentityChangedDuringAssessmentCannotBeReleased() async throws {
        let app = try fixture(), binary = app.appending(path: "Contents/MacOS/Fixture")
        try mark(app)
        do {
            try await ApplicationInstallation.finalize(app, validate: { _ in
                guard try Data(contentsOf: binary) == Data("fixture".utf8) else { throw PeerError.invalid("Changed identity") }
            }, assess: { _ in try Data("changed".utf8).write(to: binary) })
            XCTFail("Identity must be checked again after assessment")
        } catch { }
        XCTAssertTrue(hasMarker(app))
    }
    func testPublicFinalizationRejectsUnsignedApplicationWithoutClearingItsMarker() async throws {
        let app = try fixture()
        try mark(app)
        let expected = InstalledApp(name: "Fixture", bundleID: "app.synthetic.fixture", version: "1", path: app.path, teamID: "SYNTHETIC1")
        do { try await ApplicationInstallation.finalize(app, matching: expected); XCTFail("Unsigned app must fail") }
        catch { }
        XCTAssertTrue(hasMarker(app))
    }
    func testLinkedRootAndHardLinkedFilesAreRejected() async throws {
        let app = try fixture(), root = app.deletingLastPathComponent()
        try mark(app)
        let alias = root.appending(path: "Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        do {
            try await ApplicationInstallation.finalize(alias, validate: { _ in XCTFail("Linked root must fail first") }, assess: { _ in })
            XCTFail("Linked root must fail")
        } catch { }
        let binary = app.appending(path: "Contents/MacOS/Fixture")
        try mark(binary)
        try FileManager.default.linkItem(at: binary, to: root.appending(path: "ExternalHardLink"))
        do { try await ApplicationInstallation.finalize(app, validate: { _ in }, assess: { _ in }); XCTFail("Hard link must fail") }
        catch { }
        XCTAssertTrue(hasMarker(app)); XCTAssertTrue(hasMarker(binary))
    }
}
