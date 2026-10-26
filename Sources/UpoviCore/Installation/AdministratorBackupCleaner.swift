import Foundation

public enum AdministratorBackupCleaner {
    public static func requestMatches(_ request: AdministratorInstallPlan, stored: AdministratorInstallAttempt) -> Bool {
        request.id == stored.id && request.application == stored.plan.application && request.version == stored.plan.version && request.build == stored.plan.build
    }
    public static func canRestore(_ state: String) -> Bool {
        ["preparing", "backedUp", "installing", "installed", "failed", "interruptedOrFailed", "awaitingAuthorization"].contains(state)
    }
    public static func canDiscard(_ stored: AdministratorInstallAttempt, current: InstalledApp?) -> Bool {
        if stored.state == "backupDiscarded" { return stored.cleanupComplete == false }
        guard ["installed", "restored"].contains(stored.state), let current, !current.isAppStore else { return false }
        let original = stored.plan.application
        guard current.path == original.path, current.bundleID == original.bundleID,
              current.teamID != nil, current.teamID == original.teamID else { return false }
        if stored.state == "restored" { return current.version == original.version && current.build == original.build }
        if let installed = stored.installedApplication { return current == installed }
        return !stored.plan.build.isEmpty && VersionOrder.compare(current.version, stored.plan.version) == .orderedSame && current.build == stored.plan.build
    }
    private static func candidates(in job: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: nil).filter { url in
            let name = url.lastPathComponent
            if ["Original.app", "Previous.app", "Incoming.app", "Update.pkg", "Expanded"].contains(name) { return true }
            for prefix in ["Displaced-", "Restore-"] where name.hasPrefix(prefix) && name.hasSuffix(".app") {
                if UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil { return true }
            }
            return false
        }
    }
    public static func usage(in job: URL) throws -> (bytes: Int64, lowerBound: Bool) {
        var bytes: Int64 = 0, count = 0
        for root in try candidates(in: job) {
            if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            let a = try root.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey])
            if a.isRegularFile == true { bytes += Int64(a.fileAllocatedSize ?? 0) }
            if bytes >= 4_000_000_000 { return (bytes, true) }
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in iterator {
                count += 1
                let a = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileAllocatedSizeKey])
                if a.isSymbolicLink == true { iterator.skipDescendants(); continue }
                bytes += Int64(a.fileAllocatedSize ?? 0)
                if bytes >= 4_000_000_000 || count >= 100_000 { return (bytes, true) }
            }
        }
        return (bytes, false)
    }
    public static func discard(_ stored: AdministratorInstallAttempt, in job: URL, current: InstalledApp?,
                               validateCurrent: () throws -> Void, save: (AdministratorInstallAttempt) throws -> Void,
                               remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws -> AdministratorInstallAttempt {
        guard job.lastPathComponent == stored.id.uuidString, job.standardizedFileURL.path == job.path,
              job.resolvingSymlinksInPath().path == job.path, canDiscard(stored, current: current) else {
            throw PeerError.invalid("Backup cleanup requires a matching completed transaction")
        }
        if stored.state != "backupDiscarded" { try validateCurrent() }
        let paths = try candidates(in: job)
        let volume = try job.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        var count = 0
        for root in paths {
            // Never walk through a retained-data symlink. The deletion removes the link itself.
            if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            func validateVolume(_ node: URL) throws {
                let a = try node.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIdentifierKey])
                if a.isSymbolicLink == true { return }
                guard let v = a.volumeIdentifier as? NSObject, let volume, v.isEqual(volume) else { throw PeerError.invalid("Backup cleanup refuses mounted external storage") }
            }
            try validateVolume(root)
            if let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .volumeIdentifierKey]) {
                for case let node as URL in iterator {
                    count += 1
                    guard count <= 100_000 else { throw PeerError.invalid("Backup cleanup exceeds its entry limit") }
                    if try node.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { iterator.skipDescendants(); continue }
                    try validateVolume(node)
                }
            }
        }
        var result = stored
        result.state = "backupDiscarded"; result.cleanupComplete = false; result.updatedAt = Date()
        // Revocation is durable before the first deletion, including after a crash or an I/O error.
        try save(result)
        for path in paths { try remove(path) }
        result.cleanupComplete = true; result.backupBytes = 0; result.backupBytesIsLowerBound = false
        result.updatedAt = Date(); try save(result)
        return result
    }
}
