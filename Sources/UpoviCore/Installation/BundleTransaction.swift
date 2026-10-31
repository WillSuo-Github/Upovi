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
    public var retainedPath: String? {
        switch state {
        case .installed: backupPath
        case .restored: displacedPath
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
        try JSONEncoder().encode(receipt).write(to: journalDirectory.appending(path: receipt.id + ".json"), options: .atomic)
    }
    func commit(prepared: URL, replacing app: InstalledApp, newVersion: String, newBuild: String) throws -> InstallationReceipt {
        let target = URL(fileURLWithPath: app.path).standardizedFileURL
        guard target.pathExtension == "app", target.resolvingSymlinksInPath().path == target.path,
              let current = AppScanner.read(target), current.bundleID == app.bundleID, current.version == app.version,
              current.build == app.build, current.teamID == app.teamID,
              files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw InstalledApplicationChanged()
        }
        let id = UUID().uuidString, parent = target.deletingLastPathComponent()
        let backup = parent.appending(path: ".upovi-backup-\(id).app")
        let incoming = parent.appending(path: ".upovi-incoming-\(id).app")
        var receipt = InstallationReceipt(id: id, date: Date(), application: app, newVersion: newVersion, newBuild: newBuild,
                                          backupPath: backup.path, incomingPath: incoming.path, state: .prepared)
        try files.copyItem(at: prepared, to: incoming)
        do {
            try validate(incoming)
            try validateOriginal(target)
            try write(receipt)
            try files.moveItem(at: target, to: backup)
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
                        try files.moveItem(at: target, to: parent.appending(path: ".upovi-failed-\(id).app"))
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
        let parent = target.deletingLastPathComponent()
        let backup = parent.appending(path: ".upovi-backup-\(receipt.id).app")
        guard backup.path == receipt.backupPath, UUID(uuidString: receipt.id) != nil,
              target.resolvingSymlinksInPath().path == target.path, backup.resolvingSymlinksInPath().path == backup.path,
              let old = AppScanner.read(backup), old.bundleID == receipt.application.bundleID,
              old.version == receipt.application.version, old.build == receipt.application.build,
              old.teamID == receipt.application.teamID else { throw PeerError.invalid("Backup identity mismatch or backup unavailable") }
        var displaced: URL?
        if let current = AppScanner.read(target) {
            guard current.bundleID == old.bundleID, current.version == receipt.newVersion, current.build == receipt.newBuild,
                  current.teamID == (ApplicationSourceCatalog.replacementTeam(for: receipt.application) ?? old.teamID) else { throw PeerError.invalid("Current application has changed since this installation; automatic restore refused") }
            let saved = parent.appending(path: ".upovi-replaced-\(receipt.id).app")
            try files.moveItem(at: target, to: saved); displaced = saved
        } else if files.fileExists(atPath: target.path) { throw PeerError.invalid("Destination is occupied by an unknown file") }
        do { try files.moveItem(at: backup, to: target) }
        catch {
            if let displaced { try? files.moveItem(at: displaced, to: target) }
            throw error
        }
        var updated = receipt; updated.state = .restored; updated.displacedPath = displaced?.path; try write(updated)
        return updated
    }

    /// Only completed installations with a matching live replacement can relinquish recovery material.
    func discardBackup(_ receipt: InstallationReceipt, recycle: (URL) throws -> Void) throws -> InstallationReceipt {
        guard UUID(uuidString: receipt.id) != nil, [.installed, .restored].contains(receipt.state) else {
            throw PeerError.invalid("Interrupted installation backups cannot be discarded")
        }
        let journal = journalDirectory.appending(path: receipt.id + ".json")
        let data = try Data(contentsOf: journal)
        let stored = try JSONDecoder().decode(InstallationReceipt.self, from: data)
        guard stored.state == receipt.state, stored.application == receipt.application,
              stored.backupPath == receipt.backupPath, stored.displacedPath == receipt.displacedPath, stored.newVersion == receipt.newVersion,
              stored.newBuild == receipt.newBuild else { throw PeerError.invalid("Installation receipt has changed") }
        let target = URL(fileURLWithPath: receipt.application.path).standardizedFileURL
        let restored = receipt.state == .restored
        let replacementTeam = ApplicationSourceCatalog.replacementTeam(for: receipt.application) ?? receipt.application.teamID
        let backup = target.deletingLastPathComponent().appending(path: ".upovi-\(restored ? "replaced" : "backup")-\(receipt.id).app")
        guard target.resolvingSymlinksInPath().path == target.path,
              backup.path == receipt.retainedPath, backup.resolvingSymlinksInPath().path == backup.path,
              let old = AppScanner.read(backup), old.bundleID == receipt.application.bundleID,
              old.version == (restored ? receipt.newVersion : receipt.application.version),
              old.build == (restored ? receipt.newBuild : receipt.application.build),
              old.teamID == (restored ? replacementTeam : receipt.application.teamID),
              let current = AppScanner.read(target), current.bundleID == old.bundleID,
              current.teamID == (restored ? receipt.application.teamID : replacementTeam),
              current.version == (restored ? receipt.application.version : receipt.newVersion),
              current.build == (restored ? receipt.application.build : receipt.newBuild) else {
            throw PeerError.invalid("Backup or installed application changed; keep this backup for recovery")
        }
        try recycle(backup)
        var updated = stored; updated.state = .backupDiscarded
        try write(updated)
        return updated
    }
}
