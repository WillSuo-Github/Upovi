import Foundation
import Darwin

public struct ApplicationBackupArchive: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bundleName: String
}

/// Completed recovery copies are inert ZIPs. Only in-flight rename transactions contain app bundles.
enum ApplicationBackupStorage {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static var files: FileManager { .default }

    static func privateDirectory(_ directory: URL) throws {
        guard directory.standardizedFileURL.path == directory.path,
              directory.resolvingSymlinksInPath().path == directory.path else { throw PeerError.invalid("Linked recovery storage") }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try files.attributesOfItem(atPath: directory.path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              (values[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((values[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw PeerError.invalid("Recovery storage is not private")
        }
        let marker = directory.appending(path: ".metadata_never_index")
        if !files.fileExists(atPath: marker.path) { try Data().write(to: marker, options: .withoutOverwriting) }
    }

    static func job(for target: URL, id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw PeerError.invalid("Invalid recovery identifier") }
        let base = target.deletingLastPathComponent().appending(path: ".upovi-recovery-\(geteuid()).noindex")
        try privateDirectory(base)
        let job = base.appending(path: id)
        try privateDirectory(job)
        return job
    }

    static func isRawPath(_ url: URL, receipt: InstallationReceipt, kind: String) -> Bool {
        guard UUID(uuidString: receipt.id) != nil else { return false }
        let parent = URL(fileURLWithPath: receipt.application.path).deletingLastPathComponent()
        let legacy = parent.appending(path: ".upovi-\(kind)-\(receipt.id).app")
        let name = kind == "backup" ? "Original.app" : "Replaced.app"
        let managed = parent.appending(path: ".upovi-recovery-\(geteuid()).noindex/\(receipt.id)/\(name)")
        return url.path == legacy.path || url.path == managed.path
    }

    static func matchesCurrent(_ app: InstalledApp, version: String, build: String, allowNewer: Bool) -> Bool {
        if app.version == version && app.build == build { return true }
        guard allowNewer else { return false }
        let order = VersionOrder.compare(app.version, version)
        if order == .orderedDescending { return true }
        return order == .orderedSame && !build.isEmpty && !app.build.isEmpty && VersionOrder.compare(app.build, build) == .orderedDescending
    }

    static func synchronize(_ url: URL, directory: Bool = false) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PeerError.unavailable("Recovery archive operation failed") }
    }

    static func archive(_ source: URL, to destination: URL, verify: (URL) throws -> Void) throws -> ApplicationBackupArchive {
        try privateDirectory(destination.deletingLastPathComponent())
        let partial = destination.deletingLastPathComponent().appending(path: UUID().uuidString + ".partial")
        let check = destination.deletingLastPathComponent().appending(path: "Verify-" + UUID().uuidString + ".noindex")
        defer { try? files.removeItem(at: partial); try? files.removeItem(at: check) }
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, partial.path])
        let archive = ApplicationBackupArchive(path: destination.path, sha256: try BundleVerifier.sha256(of: partial), bundleName: source.lastPathComponent)
        // Use the hardened extractor before a source is relinquished; verify restored identity and signatures.
        try ArchiveExtractor.extractRecoveryZIP(partial, to: check)
        try verify(check.appending(path: archive.bundleName))
        if files.fileExists(atPath: destination.path) {
            guard destination.resolvingSymlinksInPath().path == destination.path else { throw PeerError.invalid("Linked recovery archive") }
            // A prior interrupted publication may have left an unreferenced archive. Keep it until the new one is verified.
            _ = try files.replaceItemAt(destination, withItemAt: partial)
        } else { try files.moveItem(at: partial, to: destination) }
        try synchronize(destination)
        try synchronize(destination.deletingLastPathComponent(), directory: true)
        return archive
    }

    static func extract(_ archive: ApplicationBackupArchive, expectedPath: URL, to staging: URL) throws -> URL {
        let url = URL(fileURLWithPath: archive.path)
        guard url.path == expectedPath.path, url.standardizedFileURL.path == url.path,
              url.resolvingSymlinksInPath().path == url.path,
              archive.bundleName == URL(fileURLWithPath: archive.bundleName).lastPathComponent,
              archive.bundleName.hasSuffix(".app"),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try BundleVerifier.sha256(of: url) == archive.sha256 else { throw PeerError.invalid("Recovery archive changed or unavailable") }
        try ArchiveExtractor.extractRecoveryZIP(url, to: staging)
        let bundle = staging.appending(path: archive.bundleName)
        guard bundle.resolvingSymlinksInPath().path == bundle.path, AppScanner.read(bundle) != nil else { throw PeerError.invalid("Recovery archive has no matching bundle") }
        return bundle
    }

    /// Remove only exact retained bundle registrations, including nested login items and extensions.
    static func unregister(_ bundle: URL) {
        var paths = [bundle]
        if let iterator = files.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            var count = 0
            for case let node as URL in iterator {
                count += 1
                if count > 100_000 { break }
                if (try? node.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
                if ["app", "appex", "xpc"].contains(node.pathExtension) { paths.append(node) }
            }
        }
        var failures = 0
        for path in paths.reversed() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            process.arguments = ["-u", path.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); if process.terminationStatus != 0 { failures += 1 } }
            catch { failures += 1 }
        }
        UpoviLog.recovery.info("event=backup.unregistered registrations=\(paths.count) failures=\(failures)")
    }
}

public struct BackupMaintenanceReport: Codable, Sendable {
    public var archived = 0
    public var discarded = 0
    public var protected = 0
    public var failed = 0
    public init() { }
}

extension BundleTransaction {
    /// Maintenance never operates on incomplete transactions, unknown paths, or missing/unverified live apps.
    func maintain(_ receipts: [InstallationReceipt], now: Date,
                  isRunning: (URL) -> Bool, verifyCurrent: (InstalledApp) throws -> Void) -> BackupMaintenanceReport {
        let operation = UpoviLogOperation("backup.maintenance", category: .recovery, details: "receipts=\(receipts.count)")
        var report = BackupMaintenanceReport()
        let newest = Dictionary(grouping: receipts.filter { [.installed, .restored].contains($0.state) && $0.retainedPath != nil }, by: { $0.application.path })
            .compactMapValues { $0.max { $0.retentionDate < $1.retentionDate }?.id }
        for receipt in receipts {
            if receipt.state == .backupDiscarded, receipt.cleanupPending == true {
                do { try finishPendingCleanup(receipt); report.discarded += 1 }
                catch { report.failed += 1; UpoviLog.recovery.error("event=backup.cleanupRetryFailed receipt=\(receipt.id) \(UpoviDiagnosticContext.errorSummary(error))") }
                continue
            }
            guard [.installed, .restored].contains(receipt.state) else {
                if receipt.state != .backupDiscarded {
                    // Recovery copies stay intact, but must not become launchable app-list entries.
                    let parent = URL(fileURLWithPath: receipt.application.path).deletingLastPathComponent()
                    let job = parent.appending(path: ".upovi-recovery-\(geteuid()).noindex/\(receipt.id)")
                    let candidates = [parent.appending(path: ".upovi-backup-\(receipt.id).app"),
                        parent.appending(path: ".upovi-incoming-\(receipt.id).app"), job.appending(path: "Original.app"),
                        job.appending(path: "Incoming.app"), job.appending(path: "Failed.app")]
                    for copy in candidates where copy.resolvingSymlinksInPath().path == copy.path {
                        if AppScanner.read(copy)?.bundleID == receipt.application.bundleID { ApplicationBackupStorage.unregister(copy) }
                    }
                    report.protected += 1
                }
                continue
            }
            guard let retained = receipt.retainedPath, FileManager.default.fileExists(atPath: retained) else { continue }
            let target = URL(fileURLWithPath: receipt.application.path)
            let raw = URL(fileURLWithPath: receipt.state == .restored ? (receipt.displacedPath ?? "") : receipt.backupPath)
            guard !isRunning(raw) else { report.protected += 1; continue }
            do {
                try requireStored(receipt)
                // Archiving preserves a sole remaining recovery copy even if the live app was removed.
                do {
                    guard target.resolvingSymlinksInPath().path == target.path, let current = AppScanner.read(target) else { throw PeerError.invalid("Live application unavailable; preserve recovery copy") }
                    try verifyCurrent(current)
                    let expectedTeam = receipt.state == .restored ? receipt.application.teamID : (ApplicationSourceCatalog.replacementTeam(for: receipt.application) ?? receipt.application.teamID)
                    guard current.bundleID == receipt.application.bundleID, current.teamID == expectedTeam,
                          ApplicationBackupStorage.matchesCurrent(current, version: receipt.state == .restored ? receipt.application.version : receipt.newVersion,
                              build: receipt.state == .restored ? receipt.application.build : receipt.newBuild, allowNewer: true) else { throw PeerError.invalid("Live application identity changed; preserve recovery copy") }
                } catch {
                    _ = try archiveRetainedCopy(receipt)
                    if (receipt.state == .restored ? receipt.displacedArchive : receipt.backupArchive) == nil { report.archived += 1 }
                    report.protected += 1
                    UpoviLog.recovery.warning("event=backup.retained receipt=\(receipt.id) reason=liveApplicationUnconfirmed")
                    continue
                }
                if now.timeIntervalSince(receipt.retentionDate) >= ApplicationBackupStorage.retention || newest[receipt.application.path] != receipt.id {
                    _ = try discardBackup(receipt, allowNewer: true, permanent: true) { _ in }
                    report.discarded += 1
                    UpoviLog.recovery.info("event=backup.expired receipt=\(receipt.id) app=\(UpoviDiagnosticContext.applicationID(receipt.application.id))")
                } else {
                    _ = try archiveRetainedCopy(receipt)
                    if (receipt.state == .restored ? receipt.displacedArchive : receipt.backupArchive) == nil { report.archived += 1 }
                    UpoviLog.recovery.info("event=backup.archived receipt=\(receipt.id) app=\(UpoviDiagnosticContext.applicationID(receipt.application.id))")
                }
            } catch {
                report.failed += 1
                UpoviLog.recovery.error("event=backup.maintenanceFailed receipt=\(receipt.id) \(UpoviDiagnosticContext.errorSummary(error))")
            }
        }
        operation.finish("completed", details: "archived=\(report.archived) discarded=\(report.discarded) protected=\(report.protected) failed=\(report.failed)")
        return report
    }

    /// Recovery authority is revoked durably before deletion. A crash can only leave retryable inert data.
    func finishPendingCleanup(_ receipt: InstallationReceipt) throws {
        try requireStored(receipt)
        guard receipt.state == .backupDiscarded, receipt.cleanupPending == true else { throw PeerError.invalid("Cleanup is not pending") }
        let files = FileManager.default
        for (kind, path) in [("backup", Optional(receipt.backupPath)), ("replaced", receipt.displacedPath)] {
            guard let path else { continue }
            let raw = URL(fileURLWithPath: path)
            guard ApplicationBackupStorage.isRawPath(raw, receipt: receipt, kind: kind) else { throw PeerError.invalid("Unknown pending cleanup location") }
            if files.fileExists(atPath: path) {
                guard raw.resolvingSymlinksInPath().path == raw.path,
                      let app = AppScanner.read(raw), app.bundleID == receipt.application.bundleID,
                      app.version == (kind == "backup" ? receipt.application.version : receipt.newVersion),
                      app.build == (kind == "backup" ? receipt.application.build : receipt.newBuild) else { throw PeerError.invalid("Pending cleanup copy changed") }
                try validateOriginal(raw)
                ApplicationBackupStorage.unregister(raw)
                try files.removeItem(at: raw)
            }
        }
        for (archive, restored) in [(receipt.backupArchive, false), (receipt.displacedArchive, true)] {
            guard let archive else { continue }
            let url = URL(fileURLWithPath: archive.path)
            guard url.path == archiveURL(receipt, restored: restored).path, url.resolvingSymlinksInPath().path == url.path else { throw PeerError.invalid("Unknown cleanup archive location") }
            if files.fileExists(atPath: url.path) {
                guard try BundleVerifier.sha256(of: url) == archive.sha256 else { throw PeerError.invalid("Cleanup archive changed") }
                try files.removeItem(at: url)
            }
        }
        var result = receipt; result.cleanupPending = false; try write(result)
    }
}

/// Installers may replace different apps concurrently; maintenance excludes mutations across app instances.
final class InstallationJournalLock: Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
    func unlock() { _ = flock(descriptor, LOCK_UN) }
    static func acquire(in directory: URL, exclusive: Bool) throws -> InstallationJournalLock? {
        guard directory.standardizedFileURL.path == directory.path, directory.resolvingSymlinksInPath().path == directory.path else { throw PeerError.invalid("Linked installation journal") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw PeerError.invalid("Unsafe installation journal") }
        let fd = open(directory.appending(path: "maintenance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { close(fd); throw PeerError.invalid("Unsafe installation lock") }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return InstallationJournalLock(fd)
    }
}
