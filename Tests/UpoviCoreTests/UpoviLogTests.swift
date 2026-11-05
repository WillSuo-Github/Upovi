import Darwin
import Foundation
import XCTest
@testable import UpoviCore

final class UpoviLogTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "UpoviLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func manager(_ root: URL, configuration: UpoviLogConfiguration = .development,
                         now: @escaping @Sendable () -> Date = { Date() }) -> UpoviLogManager {
        var configuration = configuration; configuration.writesToConsole = false
        return UpoviLogManager(directoryURL: root.appending(path: "Logs"), configuration: configuration, now: now)
    }
    func testRetainedSessionsContainUTCContextAndMatchSnapshotReferences() throws {
        let root = try root(), first = manager(root)
        let app = InstalledApp(name: "Private", bundleID: "app.private", version: "1", path: "/Users/private/App.app")
        UpoviDiagnosticContext.$operationID.withValue("fixture-parent") {
            let operation = UpoviLogOperation("fixture.check", category: .sources, details: UpoviDiagnosticContext.application(app), manager: first)
            first.log("response received", level: .info, category: .network)
            operation.finish()
        }
        first.flush()
        let second = manager(root)
        let text = try second.exportSnapshot()
        XCTAssertTrue(text.contains("[INFO] [network]")); XCTAssertTrue(text.contains("[operation=fixture-parent]"))
        XCTAssertTrue(text.contains("UpoviLogTests.swift:")); XCTAssertTrue(text.contains("parent=fixture-parent"))
        XCTAssertTrue(text.contains("[session=\(first.sessionID)]")); XCTAssertTrue(text.contains("Z]"))
        XCTAssertTrue(text.contains("app=\(UpoviDiagnosticContext.applicationID(app.id))"))
        XCTAssertFalse(text.contains(app.path)); XCTAssertFalse(text.contains(app.bundleID))
    }
    func testSuppressedMessagesAreLazyAndReleaseRetainsInfo() throws {
        var configuration = UpoviLogConfiguration.release; configuration.writesToConsole = false
        let manager = manager(try root(), configuration: configuration)
        var evaluated = false
        manager.log({ evaluated = true; return "secret debug" }(), level: .debug, category: .app)
        manager.log("visible info", level: .info, category: .app)
        XCTAssertFalse(evaluated)
        let text = try manager.exportSnapshot()
        XCTAssertFalse(text.contains("secret debug")); XCTAssertTrue(text.contains("visible info"))
    }
    func testRotationUnicodeTotalAndFileCountBudgetsAreHardLimits() throws {
        var configuration = UpoviLogConfiguration.development
        configuration.maximumFileByteCount = 512; configuration.maximumTotalByteCount = 1400; configuration.maximumRetainedFileCount = 2
        let manager = manager(try root(), configuration: configuration)
        for _ in 0..<12 { manager.log(String(repeating: "中文🍬", count: 500), level: .info, category: .storage) }
        manager.flush()
        let files = manager.logFileURLs(); XCTAssertLessThanOrEqual(files.count, 2)
        let sizes = try files.map { try Data(contentsOf: $0) }
        XCTAssertTrue(sizes.allSatisfy { $0.count <= 512 && String(data: $0, encoding: .utf8) != nil })
        XCTAssertLessThanOrEqual(sizes.reduce(0) { $0 + $1.count }, 1400)
        XCTAssertTrue(try manager.exportSnapshot().contains("[truncated]"))
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: manager.logDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testZeroBudgetAndBusyWriterAreVisibleWithoutUnboundedFiles() throws {
        var configuration = UpoviLogConfiguration.development; configuration.maximumTotalByteCount = 0
        let zero = manager(try root(), configuration: configuration)
        zero.log("no room", level: .info, category: .app); zero.flush()
        XCTAssertTrue(zero.logFileURLs().isEmpty)
        configuration.maximumTotalByteCount = 1000; configuration.maximumPendingByteCount = 1
        let busy = manager(try root(), configuration: configuration)
        for _ in 0..<5 { busy.log("dropped", level: .info, category: .app) }
        XCTAssertTrue(try busy.exportSnapshot().contains("Dropped entries (busy writer): 5"))
    }
    func testConcurrentAdmissionAndSnapshotKeepWholeAcceptedEntries() throws {
        var configuration = UpoviLogConfiguration.development; configuration.maximumPendingByteCount = 1024 * 1024
        let manager = manager(try root(), configuration: configuration)
        DispatchQueue.concurrentPerform(iterations: 120) { manager.log("concurrentEntry=\($0)", level: .info, category: .network) }
        let text = try manager.exportSnapshot()
        XCTAssertEqual(text.components(separatedBy: "concurrentEntry=").count - 1, 120)
        XCTAssertTrue(text.contains("Dropped entries (busy writer): 0"))
    }
    func testRetentionPrunesOldFilesAtStartupAndRotatesAtUTCMidnight() throws {
        let root = try root(); let logs = root.appending(path: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        let old = logs.appending(path: "Upovi-old.log")
        try Data("old entry".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * 86400)], ofItemAtPath: old.path)
        let clock = LogTestClock(Date())
        let manager = manager(root, now: { clock.value })
        manager.log("day one", level: .info, category: .app); manager.flush()
        clock.advance(86400)
        manager.log("day two", level: .info, category: .app); manager.flush()
        XCTAssertEqual(manager.logFileURLs().count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for file in manager.logFileURLs() {
            try FileManager.default.setAttributes([.modificationDate: clock.value.addingTimeInterval(-15 * 86400)], ofItemAtPath: file.path)
        }
        manager.log("fresh after expiry", level: .info, category: .app); manager.flush()
        let text = try manager.exportSnapshot(); XCTAssertFalse(text.contains("day one")); XCTAssertFalse(text.contains("day two"))
    }
    func testSinkAndLegacyExportRedactCredentialsPathsAndRecordForgery() throws {
        let root = try root(), manager = manager(root)
        let poisoned = "password=PASSWORD_SECRET Authorization: Bearer AUTH_SECRET https://user:URL_SECRET@api.github.com/private/SECRET_PATH?token=QUERY_SECRET /Users/private/DISK_SECRET\nFORGED_RECORD"
        manager.log(poisoned, level: .error, category: .authorization)
        manager.flush()
        let legacy = manager.logDirectory.appending(path: "Upovi-legacy.log")
        try Data("legacy token=LEGACY_SECRET\nsecond line\n".utf8).write(to: legacy)
        let text = try manager.exportSnapshot()
        for secret in ["PASSWORD_SECRET", "AUTH_SECRET", "URL_SECRET", "SECRET_PATH", "QUERY_SECRET", "DISK_SECRET", "LEGACY_SECRET"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertFalse(text.contains("\nFORGED_RECORD")); XCTAssertTrue(text.contains("\nsecond line\n"))
        XCTAssertFalse(UpoviDiagnosticContext.errorSummary(PeerError.unavailable("Authorized installer failed: RAW_OUTPUT_SECRET")).contains("RAW_OUTPUT_SECRET"))
    }
    func testUnreadableOrInvalidRetainedFileFailsExportAndSymlinkIsNotFollowed() throws {
        let root = try root(), manager = manager(root)
        manager.log("ordinary entry", level: .info, category: .app); manager.flush()
        let target = root.appending(path: "private-data")
        try Data("SYMLINK_SECRET".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: manager.logDirectory.appending(path: "Upovi-link.log"), withDestinationURL: target)
        XCTAssertFalse(try manager.exportSnapshot().contains("SYMLINK_SECRET"))
        let invalid = manager.logDirectory.appending(path: "Upovi-invalid.log")
        try Data([0xff, 0xfe, 0xff]).write(to: invalid)
        XCTAssertThrowsError(try manager.exportSnapshot())
    }
    func testDirectoryIOFailureCannotProduceFalseCompleteExport() throws {
        let root = try root(); let path = root.appending(path: "Logs")
        try Data("blocked directory".utf8).write(to: path)
        let manager = manager(root)
        manager.log("failed write", level: .error, category: .app); manager.flush()
        XCTAssertThrowsError(try manager.exportSnapshot())
    }
    func testHelperFailureProjectionRejectsFreeTextAndOnlyExportsFixedFields() {
        let data = Data("private command output TOKEN_SECRET\nUPOVI_INSTALLER_DIAGNOSTIC stage=installed.finalize domain=NSPOSIXErrorDomain code=1\nprivate trailing text".utf8)
        XCTAssertEqual(UpoviDiagnosticContext.helperFailureSummary(data), "helperStage=installed.finalize helperDomain=NSPOSIXErrorDomain helperCode=1")
        XCTAssertNil(UpoviDiagnosticContext.helperFailureSummary(Data("UPOVI_INSTALLER_DIAGNOSTIC stage=/Users/private domain=other code=1".utf8)))
        XCTAssertNil(UpoviDiagnosticContext.helperFailureSummary(Data("UPOVI_INSTALLER_DIAGNOSTIC stage=install domain=PRIVATE_SECRET code=1".utf8)))
    }
    func testErrorSummaryPreservesPOSIXUnderlyingAndFinalizationCodes() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "Operation not permitted /Applications/Private.app"])
        let text = UpoviDiagnosticContext.errorSummary(error)
        XCTAssertTrue(text.contains("code=513")); XCTAssertTrue(text.contains("NSPOSIXErrorDomain code=1")); XCTAssertFalse(text.contains("Private.app"))
        let finalization = UpoviDiagnosticContext.errorSummary(AdministratorFinalizationError(underlying))
        XCTAssertTrue(finalization.contains("finalizationCode=1")); XCTAssertTrue(finalization.contains("finalizationDomain=NSPOSIXErrorDomain"))
        let limited = UpoviDiagnosticContext.errorSummary(HTTPStatusError(statusCode: 403, retryAt: Date(), rateLimited: true))
        XCTAssertTrue(limited.contains("rateLimited=true")); XCTAssertTrue(limited.contains("retryAt="))
    }
    func testDiagnosticArchiveContainsSnapshotAndSanitizedMultiSessionLogs() async throws {
        let root = try root(), manager = manager(root)
        manager.log("authorization reached token=ZIP_SECRET", level: .info, category: .authorization)
        let report = Data("{\"schemaVersion\":2,\"applications\":[]}".utf8)
        let archive = try await DiagnosticArchive.prepare(report: report, includeLogs: true, environment: .init(version: "0.4.10", build: "fixture", sourceRevision: "fixture-revision"), manager: manager)
        let zip = root.appending(path: "export.zip"); try archive.write(to: zip)
        let listing = try await ProcessCommand().run("/usr/bin/unzip", ["-Z", "-1", zip.path])
        let archiveNames = String(decoding: listing, as: UTF8.self).split(separator: "\n").filter { !$0.hasSuffix("/") }
        XCTAssertEqual(Set(archiveNames.map(String.init)), Set(["manifest.json", "snapshot.json", "runtime.log", "README.txt"].map { "Upovi-Diagnostics/" + $0 }))
        let extracted = root.appending(path: "extracted")
        _ = try await ProcessCommand().run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        let folder = extracted.appending(path: "Upovi-Diagnostics")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(files), ["manifest.json", "snapshot.json", "runtime.log", "README.txt"])
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "snapshot.json")), report)
        let text = try String(contentsOf: folder.appending(path: "runtime.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("authorization reached")); XCTAssertFalse(text.contains("ZIP_SECRET"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["build"] as? String, "fixture"); XCTAssertEqual(manifest["automaticallyUploaded"] as? Bool, false)
        XCTAssertFalse(manifest.keys.contains("deviceName"))
    }
    func testInstrumentedHTTPPreservesBodiesButNeverWritesThemOrHeadersToLogs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticLogWire.self]
        let id = "log-http-fixture-" + UUID().uuidString
        let response = try await UpoviDiagnosticContext.$operationID.withValue(id) {
            try await HTTPTransfer.metadata(from: URL(string: "https://transport.upovi.invalid/payload?token=NETWORK_QUERY_SECRET")!, limit: 1024,
                headers: ["Authorization": "Bearer NETWORK_HEADER_SECRET"], configuration: configuration)
        }
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "NETWORK_BODY_SECRET")
        let text = try UpoviLogManager.shared.exportSnapshot()
        XCTAssertTrue(text.contains("parent=\(id)")); XCTAssertTrue(text.contains("status=200"))
        for secret in ["NETWORK_QUERY_SECRET", "NETWORK_HEADER_SECRET", "NETWORK_BODY_SECRET"] { XCTAssertFalse(text.contains(secret), secret) }
    }
    func testCurrentAndCancelledOperationsAreNotReportedAsErrors() throws {
        let manager = manager(try root())
        UpoviLogOperation("current.fixture", category: .installation, manager: manager).fail(ApplicationAlreadyCurrent())
        UpoviLogOperation("cancel.fixture", category: .installation, manager: manager).fail(CancellationError())
        let text = try manager.exportSnapshot()
        XCTAssertTrue(text.contains("event=alreadyCurrent")); XCTAssertTrue(text.contains("event=cancelled"))
        XCTAssertFalse(text.contains("[ERROR]")); XCTAssertFalse(text.contains("event=failed"))
    }
    func testGatekeeperClassificationNeverExportsItsRawOutputOrInventsApproval() {
        let rejected = Data("/Users/PRIVATE/Secret.app: rejected\nsource=Unnotarized Developer ID\norigin=PRIVATE_DEVELOPER".utf8)
        XCTAssertEqual(ApplicationInstallation.assessmentClassification(rejected), "unnotarizedDeveloperID")
        XCTAssertEqual(ApplicationInstallation.assessmentClassification(Data("source=Notarized Developer ID".utf8)), "notarizedDeveloperID")
        XCTAssertEqual(ApplicationInstallation.assessmentClassification(Data("source=no usable signature".utf8)), "noUsableSignature")
        XCTAssertEqual(ApplicationInstallation.assessmentClassification(Data("Unnotarized Developer ID source=Notarized Developer ID".utf8)), "unclassified")
    }
    func testLogExclusionDoesNotReadBrokenLogDirectory() async throws {
        let root = try root(); try Data().write(to: root.appending(path: "Logs"))
        let archive = try await DiagnosticArchive.prepare(report: Data("{}".utf8), includeLogs: false,
            environment: .init(version: "fixture", build: "1", sourceRevision: "fixture"), manager: manager(root))
        XCTAssertFalse(archive.isEmpty)
    }
}

private final class LogTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private final class DiagnosticLogWire: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.upovi.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data("NETWORK_BODY_SECRET".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
