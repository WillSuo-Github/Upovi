import Darwin
import XCTest
@testable import UpoviCore

final class ReviewedAppleSoftwareTests: XCTestCase {
    private func app(version: String = "1.2", build: String = "76", bundleID: String = "com.apple.IconComposer",
                     team: String? = "59GAB85EFG", store: Bool = false) -> InstalledApp {
        .init(name: "Icon Composer", bundleID: bundleID, version: version, build: build,
              path: "/Applications/Icon Composer.app", teamID: team, isAppStore: store)
    }

    func testReviewIsBoundToExactReleaseIdentity() {
        XCTAssertNotNil(ReviewedAppleSoftware.executableSHA256(for: app()))
        XCTAssertNotNil(ReviewedAppleSoftware.executableSHA256(for: app(version: "1.1", build: "59")))
        for unsupported in [app(version: "1.3"), app(build: "77"), app(version: "1.2.0"),
                            app(bundleID: "com.apple.Other"), app(team: "OTHERTEAM1"), app(team: nil), app(store: true)] {
            XCTAssertNil(ReviewedAppleSoftware.executableSHA256(for: unsupported))
        }
    }

    func testOnlyExactNotAppToolFailureCanUseReviewedTrust() {
        let bundle = URL(fileURLWithPath: "/private/Fixture.app")
        let data = Data("\(bundle.path): rejected (the code is valid but does not seem to be an app)\n".utf8)
        let error = PeerError.unavailable("System tool failed: spctl (3)")
        XCTAssertTrue(ApplicationInstallation.isNotAppAssessmentFailure(error, data: data, bundle: bundle))
        for rejection in [data + Data("source=revoked\n".utf8), Data("rejected\nsource=Unnotarized Developer ID\n".utf8),
                          Data("/different.app: rejected (the code is valid but does not seem to be an app)\n".utf8)] {
            XCTAssertFalse(ApplicationInstallation.isNotAppAssessmentFailure(error, data: rejection, bundle: bundle))
        }
        for failure: Error in [CancellationError(), PeerError.unavailable("System tool failed: spctl (1)"),
                               PeerError.unavailable("System tool output exceeded its size limit")] {
            XCTAssertFalse(ApplicationInstallation.isNotAppAssessmentFailure(failure, data: data, bundle: bundle))
        }
    }

    // Optional real-artifact regressions. The official DMG is downloaded and checksum-checked
    // separately; each test mutates only its own temporary copy, never a user's application.
    private func officialCopy() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["UPOVI_REVIEWED_APPLE_FIXTURE"] else {
            throw XCTSkip("Set UPOVI_REVIEWED_APPLE_FIXTURE to the verified official Icon Composer 1.2 bundle")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-AppleTrust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let copy = root.appending(path: "Prepared.app")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        XCTAssertEqual(AppScanner.read(copy)?.version, "1.2")
        XCTAssertEqual(AppScanner.read(copy)?.build, "76")
        try mark(copy)
        return copy
    }
    private func mark(_ bundle: URL) throws {
        let result = "0081;00000000;UpoviTest;fixture".withCString {
            setxattr(bundle.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(.EIO) }
    }
    private func hasQuarantine(_ bundle: URL) -> Bool {
        getxattr(bundle.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
    func testOfficialAppleReleaseFinalizesAndCanBeRecognizedAsInstalled() async throws {
        let copy = try officialCopy(), expected = try XCTUnwrap(AppScanner.read(copy))
        // This must not broaden the Developer ID-only signature-only download route.
        XCTAssertThrowsError(try BundleVerifier.checkDeveloperIDSignature(copy, like: expected))
        XCTAssertTrue(try ReviewedAppleSoftware.verifyIfReviewed(copy))
        try await ApplicationInstallation.finalize(copy, matching: expected)
        XCTAssertFalse(hasQuarantine(copy))
        XCTAssertTrue(try BundleVerifier.selectedUpdateIsInstalled(expected,
            candidate: .init(version: "1.2", build: "76", source: "Fixture", isCommunity: false, url: nil)))
        XCTAssertThrowsError(try BundleVerifier.checkInstallationSignature(copy, like: app(bundleID: "com.apple.Other")))
    }
    func testTamperedOfficialResourcesAreRejectedAndRemainQuarantined() async throws {
        let copy = try officialCopy(), expected = try XCTUnwrap(AppScanner.read(copy))
        let resources = copy.appending(path: "Contents/Resources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isRegularFileKey]))
        let resource = try XCTUnwrap(enumerator.compactMap { $0 as? URL }.first {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        })
        try Data("tampered sealed resource".utf8).write(to: resource)
        XCTAssertThrowsError(try ReviewedAppleSoftware.verifyIfReviewed(copy))
        do { try await ApplicationInstallation.assess(copy); XCTFail("Assessment cannot accept tampered Apple resources") }
        catch { }
        do { try await ApplicationInstallation.finalize(copy, matching: expected); XCTFail("Tampered resources must fail") }
        catch { }
        XCTAssertTrue(hasQuarantine(copy))
    }
    func testReplacedExecutableAndAdHocResigningCannotUseReviewedTrust() async throws {
        let copy = try officialCopy(), executable = copy.appending(path: "Contents/MacOS/Icon Composer")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        _ = try await ProcessCommand().run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", copy.path])
        XCTAssertThrowsError(try BundleVerifier.checkInstallationSignature(copy, like: app()))
        do { try await ApplicationInstallation.assess(copy); XCTFail("Ad hoc lookalike must fail") }
        catch { }
        XCTAssertTrue(hasQuarantine(copy))
    }
    func testCancelledOfficialAssessmentPreservesQuarantine() async throws {
        let copy = try officialCopy()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ApplicationInstallation.assess(copy)
        }
        do { try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        XCTAssertTrue(hasQuarantine(copy))
    }
}
