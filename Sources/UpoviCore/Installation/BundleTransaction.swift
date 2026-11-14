import Foundation

public struct InstalledApplicationChanged: LocalizedError, Sendable {
    public init() { }
    public var errorDescription: String? { "Installed application changed, is linked, or its parent is not writable" }
}

public struct InstallationReceipt: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, backedUp, installed, restored, failed, backupDiscarded }
    public let id: String
    public let date: Date
    public let application: InstalledApp
    public let newVersion: String
    public let newBuild: String
    public let backupPath: String
    public let incomingPath: String
    public var state: State
    public var displacedPath: String? = nil
    public var backupArchive: ApplicationBackupArchive? = nil
    public var displacedArchive: ApplicationBackupArchive? = nil
    public var cleanupPending: Bool? = nil
    public var retainedAt: Date? = nil
    public var retentionDate: Date { retainedAt ?? date }
    public var retainedPath: String? {
        switch state {
        case .installed: backupArchive?.path ?? backupPath
        case .restored: displacedArchive?.path ?? displacedPath
        default: nil
        }
    }
}

/// All rename operations stay on the destination volume. Original bundles are retained for recovery.
struct BundleTransaction {
    let journalDirectory: URL
    let validate: @Sendable (URL) throws -> Void
    var validateOriginal: @Sendable (URL) throws -> Void = { _ in }
    var afterBackup: @Sendable () throws -> Void = { }
    private let files = FileManager.default

    func write(_ receipt: InstallationReceipt) throws {
        guard UUID(uuidString: receipt.id) != nil else { throw PeerError.invalid("Invalid installation receipt") }
        try files.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let journal = journalDirectory.appending(path: receipt.id + ".json")
        try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
        try ApplicationBackupStorage.synchronize(journal)
        try ApplicationBackupStorage.synchronize(journalDirectory, directory: true)
    }
    func commit(prepared: URL, replacing app: InstalledApp, newVersion: String, newBuild: String) throws -> InstallationReceipt {
        let target = URL(fileURLWithPath: app.path).standardizedFileURL
        guard target.pathExtension == "app", target.resolvingSymlinksInPath().path == target.path,
              let current = AppScanner.read(target), current.bundleID == app.bundleID, current.version == app.version,
              current.build == app.build, current.teamID == app.teamID,
              files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw InstalledApplicationChanged()
        }
        let id = UUID().uuidString
        let job = try ApplicationBackupStorage.job(for: target, id: id)
        let backup = job.appending(path: "Original.app")
        let incoming = job.appending(path: "Incoming.app")
        var receipt = InstallationReceipt(id: id, date: Date(), application: app, newVersion: newVersion, newBuild: newBuild,
                                          backupPath: backup.path, incomingPath: incoming.path, state: .prepared)
        do {
            try write(receipt)
            try files.copyItem(at: prepared, to: incoming)
            try validate(incoming)
            try validateOriginal(target)
            guard let unchanged = AppScanner.read(target), unchanged.bundleID == app.bundleID,
                  unchanged.teamID == app.teamID, unchanged.version == app.version, unchanged.build == app.build else {
                throw InstalledApplicationChanged()
            }
            try files.moveItem(at: target, to: backup)
            ApplicationBackupStorage.unregister(backup)
            try validateOriginal(backup)
            receipt.state = .backedUp; try write(receipt)
            try afterBackup()
            try files.moveItem(at: incoming, to: target)
            try validate(target)
            receipt.state = .installed; try write(receipt)
            return receipt
        } catch {
            // Preserve any failed new bundle separately; never remove the old backup to make space.
            if files.fileExists(atPath: backup.path) {
                do {
                    if files.fileExists(atPath: target.path) {
                        let failed = job.appending(path: "Failed.app")
                        try files.moveItem(at: target, to: failed)
                        ApplicationBackupStorage.unregister(failed)
                    }
                    try files.moveItem(at: backup, to: target)
                } catch { throw PeerError.unavailable("Automatic recovery failed. Original backup: \(backup.path)") }
            }
            if files.fileExists(atPath: incoming.path) { try? files.removeItem(at: incoming) }
            receipt.state = .failed; try? write(receipt)
            throw error
        }
    }
    func restore(_ receipt: InstallationReceipt) throws -> InstallationReceipt {
        let target = URL(fileURLWithPath: receipt.application.path).standardizedFileURL
        try requireStored(receipt)
        guard receipt.state != .backupDiscarded else { throw PeerError.invalid("Backup was discarded") }
        let staging = try ApplicationBackupStorage.job(for: target, id: receipt.id).appending(path: "Restore-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        let backup: URL
        if let archive = receipt.backupArchive {
            backup = try ApplicationBackupStorage.extract(archive, expectedPath: archiveURL(receipt, restored: false), to: staging)
            try validateOriginal(backup)
        } else { backup = URL(fileURLWithPath: receipt.backupPath) }
        guard ApplicationBackupStorage.isRawPath(URL(fileURLWithPath: receipt.backupPath), receipt: receipt, kind: "backup"), UUID(uuidString: receipt.id) != nil,
              target.resolvingSymlinksInPath().path == target.path, backup.resolvingSymlinksInPath().path == backup.path,
              let old = AppScanner.read(backup), old.bundleID == receipt.application.bundleID,
              old.version == receipt.application.version, old.build == receipt.application.build,
              old.teamID == receipt.application.teamID else { throw PeerError.invalid("Backup identity mismatch or backup unavailable") }
        var displaced: URL?
        if let current = AppScanner.read(target) {
            guard current.bundleID == old.bundleID, current.version == receipt.newVersion, current.build == receipt.newBuild,
                  current.teamID == (ApplicationSourceCatalog.replacementTeam(for: receipt.application) ?? old.teamID) else { throw PeerError.invalid("Current application has changed since this installation; automatic restore refused") }
            let saved = try ApplicationBackupStorage.job(for: target, id: receipt.id).appending(path: "Replaced.app")
            try files.moveItem(at: target, to: saved); displaced = saved
            ApplicationBackupStorage.unregister(saved)
        } else if files.fileExists(atPath: target.path) { throw PeerError.invalid("Destination is occupied by an unknown file") }
        do { try files.moveItem(at: backup, to: target) }
        catch {
            if let displaced { try? files.moveItem(at: displaced, to: target) }
            throw error
        }
        var updated = receipt; updated.state = .restored; updated.retainedAt = Date(); updated.displacedPath = displaced?.path; try write(updated)
        return updated
    }

    func archiveURL(_ receipt: InstallationReceipt, restored: Bool) -> URL {
        journalDirectory.appending(path: "Backups.noindex").appending(path: receipt.id + (restored ? "-replaced.zip" : "-original.zip"))
    }

    func requireStored(_ receipt: InstallationReceipt) throws {
        guard UUID(uuidString: receipt.id) != nil else { throw PeerError.invalid("Invalid installation receipt") }
        let stored = try JSONDecoder().decode(InstallationReceipt.self, from: Data(contentsOf: journalDirectory.appending(path: receipt.id + ".json")))
        guard stored.application == receipt.application else {
            throw PeerError.invalid("Installation receipt has changed")
        }
        guard stored.id == receipt.id, stored.date == receipt.date, stored.state == receipt.state, stored.backupPath == receipt.backupPath,
              stored.incomingPath == receipt.incomingPath, stored.displacedPath == receipt.displacedPath,
              stored.newVersion == receipt.newVersion, stored.newBuild == receipt.newBuild,
              stored.backupArchive == receipt.backupArchive, stored.displacedArchive == receipt.displacedArchive,
              stored.cleanupPending == receipt.cleanupPending, stored.retainedAt == receipt.retainedAt else { throw PeerError.invalid("Installation receipt has changed") }
    }

    /// Publish the verified archive in the journal before removing the runnable source.
    func archiveRetainedCopy(_ receipt: InstallationReceipt) throws -> InstallationReceipt {
        try requireStored(receipt)
        guard [.installed, .restored].contains(receipt.state) else { return receipt }
        let restored = receipt.state == .restored
        let raw = URL(fileURLWithPath: restored ? (receipt.displacedPath ?? "") : receipt.backupPath)
        guard ApplicationBackupStorage.isRawPath(raw, receipt: receipt, kind: restored ? "replaced" : "backup") else {
            throw PeerError.invalid("Unrecognized backup location")
        }
        var result = receipt
        let archive = restored ? receipt.displacedArchive : receipt.backupArchive
        if archive == nil {
            guard let metadata = AppScanner.read(raw), matchesRetained(metadata, receipt: receipt),
                  raw.resolvingSymlinksInPath().path == raw.path else { throw PeerError.invalid("Backup identity mismatch") }
            try validateOriginal(raw)
            let value = try ApplicationBackupStorage.archive(raw, to: archiveURL(receipt, restored: restored), verify: { copy in
                guard let copied = AppScanner.read(copy), matchesRetained(copied, receipt: receipt) else { throw PeerError.invalid("Archived backup identity mismatch") }
                try validateOriginal(copy)
            })
            if restored { result.displacedArchive = value } else { result.backupArchive = value }
            try write(result)
        } else if files.fileExists(atPath: raw.path) {
            // An interrupted migration can leave both forms. Verify the durable archive before retrying removal.
            let staging = try ApplicationBackupStorage.job(for: URL(fileURLWithPath: receipt.application.path), id: receipt.id).appending(path: "Verify-" + UUID().uuidString)
            defer { try? files.removeItem(at: staging) }
            let copy = try ApplicationBackupStorage.extract(archive!, expectedPath: archiveURL(receipt, restored: restored), to: staging)
            guard let metadata = AppScanner.read(copy), matchesRetained(metadata, receipt: receipt) else { throw PeerError.invalid("Archived backup identity mismatch") }
            try validateOriginal(copy)
        }
        if files.fileExists(atPath: raw.path) {
            guard raw.resolvingSymlinksInPath().path == raw.path, let metadata = AppScanner.read(raw), matchesRetained(metadata, receipt: receipt) else { throw PeerError.invalid("Backup changed during migration") }
            ApplicationBackupStorage.unregister(raw)
            try files.removeItem(at: raw)
        }
        return result
    }

    private func matchesRetained(_ app: InstalledApp, receipt: InstallationReceipt) -> Bool {
        let restored = receipt.state == .restored
        return app.bundleID == receipt.application.bundleID
            && app.teamID == (restored ? (ApplicationSourceCatalog.replacementTeam(for: receipt.application) ?? receipt.application.teamID) : receipt.application.teamID)
            && app.version == (restored ? receipt.newVersion : receipt.application.version)
            && app.build == (restored ? receipt.newBuild : receipt.application.build)
    }

    /// Only completed installations with a matching live replacement can relinquish recovery material.
    func discardBackup(_ receipt: InstallationReceipt, allowNewer: Bool = false, permanent: Bool = false, recycle: (URL) throws -> Void) throws -> InstallationReceipt {
        guard UUID(uuidString: receipt.id) != nil, [.installed, .restored].contains(receipt.state) else {
            throw PeerError.invalid("Interrupted installation backups cannot be discarded")
        }
        try requireStored(receipt)
        let stored = receipt
        let target = URL(fileURLWithPath: receipt.application.path).standardizedFileURL
        let restored = receipt.state == .restored
        let replacementTeam = ApplicationSourceCatalog.replacementTeam(for: receipt.application) ?? receipt.application.teamID
        let raw = URL(fileURLWithPath: restored ? (receipt.displacedPath ?? "") : receipt.backupPath)
        guard ApplicationBackupStorage.isRawPath(raw, receipt: receipt, kind: restored ? "replaced" : "backup") else { throw PeerError.invalid("Unrecognized backup location") }
        let staging = try ApplicationBackupStorage.job(for: target, id: receipt.id).appending(path: "Cleanup-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        let archive = restored ? receipt.displacedArchive : receipt.backupArchive
        let backup = try archive.map { try ApplicationBackupStorage.extract($0, expectedPath: archiveURL(receipt, restored: restored), to: staging) } ?? raw
        guard target.resolvingSymlinksInPath().path == target.path, backup.resolvingSymlinksInPath().path == backup.path,
              let old = AppScanner.read(backup), matchesRetained(old, receipt: receipt),
              let current = AppScanner.read(target), current.bundleID == old.bundleID,
              current.teamID == (restored ? receipt.application.teamID : replacementTeam),
              ApplicationBackupStorage.matchesCurrent(current, version: restored ? receipt.application.version : receipt.newVersion,
                  build: restored ? receipt.application.build : receipt.newBuild, allowNewer: allowNewer) else {
            throw PeerError.invalid("Backup or installed application changed; keep this backup for recovery")
        }
        try validateOriginal(backup)
        let retained = URL(fileURLWithPath: receipt.retainedPath!)
        if permanent {
            var revoked = receipt; revoked.state = .backupDiscarded; revoked.cleanupPending = true
            try write(revoked)
            try finishPendingCleanup(revoked)
            revoked.cleanupPending = false
            return revoked
        }
        ApplicationBackupStorage.unregister(raw)
        try recycle(retained)
        var updated = stored; updated.state = .backupDiscarded; updated.cleanupPending = true
        try write(updated)
        try finishPendingCleanup(updated)
        updated.cleanupPending = false
        return updated
    }
}
