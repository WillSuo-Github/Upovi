import Darwin
import Foundation
import UpoviCore

/// Runs only as a verified, root-owned copy after a fresh macOS authorization prompt.
@main
struct UpoviInstaller {
    private static var files: FileManager { .default }
    private static let base = URL(fileURLWithPath: "/Library/Application Support/Upovi/PrivilegedInstallations")

    static func main() async {
        do {
            guard geteuid() == 0, CommandLine.arguments.count == 2 else { throw PeerError.invalid("Administrator authorization is required") }
            let input = URL(fileURLWithPath: CommandLine.arguments[1])
            let attributes = try files.attributesOfItem(atPath: input.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try CanonicalFilePath.resolve(input) == input.path, owner == 0, size <= 65536,
                  mode & 0o022 == 0 else { throw PeerError.invalid("Unsafe administrator plan file (owner=\(owner), mode=\(String(mode, radix: 8)), bytes=\(size))") }
            let plan = try JSONDecoder().decode(AdministratorInstallPlan.self, from: Data(contentsOf: input))
            try plan.validate()
            let result = try await execute(plan)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        } catch {
            fputs("Upovi administrator installation did not complete: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func requireRootOwnership(_ url: URL) throws {
        guard try CanonicalFilePath.resolve(url) == url.path else { throw PeerError.invalid("Linked administrator transaction directory") }
        let attributes = try files.attributesOfItem(atPath: url.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard owner == 0, mode & 0o022 == 0 else {
            throw PeerError.invalid("Administrator transaction storage is not protected (owner=\(owner), mode=\(String(mode, radix: 8)))")
        }
    }

    private static func save(_ attempt: AdministratorInstallAttempt, in job: URL) throws {
        let url = job.appending(path: "receipt.json")
        try JSONEncoder().encode(attempt).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let directory = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw PeerError.unavailable("Cannot synchronize administrator receipt directory") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw PeerError.unavailable("Cannot persist administrator receipt replacement") }
    }

    private static func matches(_ app: InstalledApp, _ expected: InstalledApp) -> Bool {
        app.bundleID == expected.bundleID && app.teamID == expected.teamID && app.version == expected.version && app.build == expected.build
    }

    private static func execute(_ supplied: AdministratorInstallPlan) async throws -> AdministratorInstallAttempt {
        let parent = base.deletingLastPathComponent()
        if !files.fileExists(atPath: parent.path) { try files.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try requireRootOwnership(parent)
        if !files.fileExists(atPath: base.path) { try files.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try requireRootOwnership(base)
        let lockFile = open(base.appending(path: "transaction.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFile >= 0 else { throw PeerError.unavailable("Cannot open administrator transaction lock") }
        defer { _ = flock(lockFile, LOCK_UN); close(lockFile) }
        guard flock(lockFile, LOCK_EX) == 0 else { throw PeerError.unavailable("Cannot lock administrator transactions") }
        let job = base.appending(path: supplied.id.uuidString)
        if [.restore, .discardBackup, .inspect].contains(supplied.operation) {
            try requireRootOwnership(job)
            let journal = job.appending(path: "receipt.json")
            try requireRootOwnership(journal)
            let a = try files.attributesOfItem(atPath: journal.path)
            guard a[.type] as? FileAttributeType == .typeRegular, (a[.size] as? NSNumber)?.intValue ?? Int.max <= 65536 else { throw PeerError.invalid("Invalid administrator journal") }
            var original = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: Data(contentsOf: journal))
            guard AdministratorBackupCleaner.requestMatches(supplied, stored: original) else { throw PeerError.invalid("Administrator journal identity or selected-version mismatch") }
            try original.plan.validate()
            if supplied.operation == .inspect {
                let usage = try AdministratorBackupCleaner.usage(in: job)
                original.backupBytes = usage.bytes; original.backupBytesIsLowerBound = usage.lowerBound
                try save(original, in: job); return original
            }
            if supplied.operation == .discardBackup {
                return try AdministratorBackupCleaner.discard(original, in: job, current: AppScanner.read(URL(fileURLWithPath: original.plan.application.path)),
                    validateCurrent: { try BundleVerifier.checkSignature(URL(fileURLWithPath: original.plan.application.path), like: original.plan.application) },
                    save: { try save($0, in: job) })
            }
            guard AdministratorBackupCleaner.canRestore(original.state) else { throw PeerError.invalid("Recovery is unavailable after backup cleanup or completed restoration") }
            return try restore(original, job: job)
        }
        try files.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try requireRootOwnership(job)
        let target = URL(fileURLWithPath: supplied.application.path)
        let targetVolume = try target.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let jobVolume = try job.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let a = targetVolume as? NSObject, let b = jobVolume as? NSObject, a.isEqual(b) else {
            throw PeerError.invalid("Administrator backup and destination must be on the same volume")
        }
        guard let current = AppScanner.read(target), !current.isAppStore, matches(current, supplied.application) else {
            throw PeerError.invalid("Application changed before administrator installation")
        }
        try BundleVerifier.checkSignature(target, like: supplied.application)
        let available = (try files.attributesOfFileSystem(forPath: job.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let required = max(6_000_000_000, allocatedBytes(in: target) * 2 + 4_000_000_000)
        guard available > required else { throw PeerError.unavailable("Insufficient free space for protected backup and package expansion") }
        var attempt = AdministratorInstallAttempt(plan: supplied, state: "preparing")
        try save(attempt, in: job)
        do {
            let backup = job.appending(path: "Original.app")
            try files.copyItem(at: target, to: backup)
            try BundleVerifier.checkSignature(backup, like: supplied.application)
            guard let snapshot = AppScanner.read(backup), matches(snapshot, supplied.application) else {
                throw PeerError.invalid("Application changed while making the protected backup")
            }
            attempt.state = "backedUp"; try save(attempt, in: job)
            if supplied.operation == .package {
                let package = job.appending(path: "Update.pkg")
                try files.copyItem(at: URL(fileURLWithPath: supplied.artifactPath), to: package)
                try await InstallerPackageVerifier.validate(package, sha256: supplied.sha256!, app: supplied.application)
                let expanded = job.appending(path: "Expanded")
                try await expand(package, to: expanded)
                let matches = matchingApps(in: expanded, bundleID: supplied.application.bundleID)
                guard matches.count == 1 else { throw PeerError.invalid("PKG must contain exactly one verifiable matching application payload") }
                try validateUpdate(matches[0], plan: supplied)
                attempt.state = "installing"; try save(attempt, in: job)
                _ = try await ProcessCommand().run("/usr/sbin/installer", ["-pkg", package.path, "-target", "/"], timeoutSeconds: 1800, outputFile: job.appending(path: "installer.log"))
            } else {
                let incoming = job.appending(path: "Incoming.app")
                try files.copyItem(at: URL(fileURLWithPath: supplied.artifactPath), to: incoming)
                try validateUpdate(incoming, plan: supplied)
                guard let replacement = AppScanner.read(incoming) else { throw PeerError.invalid("Prepared application is missing") }
                try await ApplicationInstallation.finalize(incoming, matching: replacement)
                attempt.state = "installing"; try save(attempt, in: job)
                try files.moveItem(at: target, to: job.appending(path: "Previous.app"))
                try files.moveItem(at: incoming, to: target)
            }
            try validateUpdate(target, plan: supplied)
            if supplied.operation == .package {
                guard let installed = AppScanner.read(target) else { throw PeerError.invalid("Installed application is missing") }
                try await ApplicationInstallation.finalize(target, matching: installed)
            }
            try ApplicationInstallation.verifyFinalized(target)
            attempt.installedApplication = AppScanner.read(target)
            if let usage = try? AdministratorBackupCleaner.usage(in: job) {
                attempt.backupBytes = usage.bytes; attempt.backupBytesIsLowerBound = usage.lowerBound
            }
            attempt.state = "installed"; attempt.updatedAt = Date(); try save(attempt, in: job)
            return attempt
        } catch {
            attempt.state = "failed"; attempt.updatedAt = Date(); try? save(attempt, in: job)
            // Preserve the full transaction for explicit recovery; PKG scripts are not automatically reversed.
            throw error
        }
    }

    private static func validateUpdate(_ url: URL, plan: AdministratorInstallPlan) throws {
        _ = try BundleVerifier.validate(url, replacing: plan.application, expectedVersion: plan.version, expectedBuild: plan.build)
        guard let executable = Bundle(url: url)?.executableURL else { throw PeerError.invalid("Missing update executable") }
        try MachOCompatibility.validate(executable)
    }

    private static func matchingApps(in root: URL, bundleID: String) -> [URL] {
        guard let iterator = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var result: [URL] = []
        while let url = iterator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
            if url.pathExtension == "app" {
                iterator.skipDescendants()
                if AppScanner.read(url)?.bundleID == bundleID { result.append(url) }
            }
        }
        return result
    }

    private static func allocatedBytes(in root: URL) -> Int64 {
        guard let iterator = files.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var result: Int64 = 0
        while let url = iterator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { iterator.skipDescendants() }
            else { result += Int64(values.fileSize ?? 0) }
            if result > 4_000_000_000 { break }
        }
        return result
    }

    private static func expand(_ package: URL, to destination: URL) async throws {
        let tool = ProcessCommand()
        let monitor = Task {
            while !Task.isCancelled {
                if allocatedBytes(in: destination) > 4_000_000_000 { tool.cancel(); return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { monitor.cancel() }
        _ = try await tool.run("/usr/sbin/pkgutil", ["--expand-full", package.path, destination.path])
        guard allocatedBytes(in: destination) <= 4_000_000_000 else { throw PeerError.invalid("Expanded PKG exceeds the safety limit") }
    }

    private static func restore(_ stored: AdministratorInstallAttempt, job: URL) throws -> AdministratorInstallAttempt {
        let plan = stored.plan, target = URL(fileURLWithPath: plan.application.path), backup = job.appending(path: "Original.app")
        try BundleVerifier.checkSignature(backup, like: plan.application)
        guard let snapshot = AppScanner.read(backup), matches(snapshot, plan.application) else {
            throw PeerError.invalid("Protected backup version does not match its root journal")
        }
        if files.fileExists(atPath: target.path) {
            guard let current = AppScanner.read(target), AdministratorRecoveryPolicy.permits(current: current,
                  original: plan.application, selectedVersion: plan.version, selectedBuild: plan.build) else {
                throw PeerError.invalid("Recovery refuses to overwrite an unrelated or externally updated application")
            }
            try BundleVerifier.checkSignature(target, like: plan.application)
        }
        let incoming = job.appending(path: "Restore-\(UUID().uuidString).app")
        try files.copyItem(at: backup, to: incoming)
        try BundleVerifier.checkSignature(incoming, like: plan.application)
        var displaced: URL?
        if files.fileExists(atPath: target.path) {
            let saved = job.appending(path: "Displaced-\(UUID().uuidString).app")
            try files.moveItem(at: target, to: saved); displaced = saved
        }
        do { try files.moveItem(at: incoming, to: target) }
        catch { if let displaced { try? files.moveItem(at: displaced, to: target) }; throw error }
        var result = stored; result.state = "restored"; result.updatedAt = Date()
        if let usage = try? AdministratorBackupCleaner.usage(in: job) {
            result.backupBytes = usage.bytes; result.backupBytesIsLowerBound = usage.lowerBound
        }
        try save(result, in: job)
        return result
    }
}
