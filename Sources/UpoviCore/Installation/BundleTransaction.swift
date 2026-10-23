import Foundation

public struct InstallationReceipt: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, backedUp, installed, restored, failed }
    public let id: String
    public let date: Date
    public let application: InstalledApp
    public let newVersion: String
    public let newBuild: String
    public let backupPath: String
    public let incomingPath: String
    public var state: State
}

/// All rename operations stay on the destination volume. Original bundles are retained for recovery.
struct BundleTransaction {
    let journalDirectory: URL
    let validate: @Sendable (URL) throws -> Void
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
            throw PeerError.invalid("Installed application changed, is linked, or its parent is not writable")
        }
        let id = UUID().uuidString, parent = target.deletingLastPathComponent()
        let backup = parent.appending(path: ".upovi-backup-\(id).app")
        let incoming = parent.appending(path: ".upovi-incoming-\(id).app")
        var receipt = InstallationReceipt(id: id, date: Date(), application: app, newVersion: newVersion, newBuild: newBuild,
                                          backupPath: backup.path, incomingPath: incoming.path, state: .prepared)
        try files.copyItem(at: prepared, to: incoming)
        do {
            try validate(incoming)
            try write(receipt)
            try files.moveItem(at: target, to: backup)
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
                  current.teamID == old.teamID else { throw PeerError.invalid("Current application has changed since this installation; automatic restore refused") }
            let saved = parent.appending(path: ".upovi-replaced-\(UUID().uuidString).app")
            try files.moveItem(at: target, to: saved); displaced = saved
        } else if files.fileExists(atPath: target.path) { throw PeerError.invalid("Destination is occupied by an unknown file") }
        do { try files.moveItem(at: backup, to: target) }
        catch {
            if let displaced { try? files.moveItem(at: displaced, to: target) }
            throw error
        }
        var updated = receipt; updated.state = .restored; try write(updated)
        return updated
    }
}
