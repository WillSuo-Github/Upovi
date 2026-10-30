import AppKit
import Darwin
import Foundation
import UpoviCore

@main struct UpoviStoreInstaller {
    static func main() async {
        do {
            guard geteuid() == 0 else { throw PeerError.invalid("Administrator authorization is required") }
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2 else { throw PeerError.invalid("Explicit protected Store plan and helper required") }
            let input = URL(fileURLWithPath: args[0]), bridge = URL(fileURLWithPath: args[1])
            let staging = input.deletingLastPathComponent()
            guard staging.deletingLastPathComponent().path == "/private/var/tmp", staging.lastPathComponent.hasPrefix("upovi-store-authorized."),
                  (try CanonicalFilePath.resolve(staging)) == staging.path else { throw PeerError.invalid("A protected Store authorization directory is required") }
            for file in [staging, input, bridge] { try requireRoot(file) }
            guard input.deletingLastPathComponent() == bridge.deletingLastPathComponent(),
                  let team = AdministratorAuthorization.teamID(at: URL(fileURLWithPath: CommandLine.arguments[0])) else {
                throw PeerError.invalid("Protected Store helpers must share a verified directory")
            }
            _ = try await ProcessCommand().run("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", "-R",
                AppStoreUpdatePlan.requirement(identifier: "app.upovi.StoreBridge", hostTeam: team), bridge.path])
            guard (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 65536 else { throw PeerError.invalid("Store plan too large") }
            let plan = try JSONDecoder().decode(AppStoreUpdatePlan.self, from: Data(contentsOf: input))
            try plan.validate()
            let console = try FileManager.default.attributesOfItem(atPath: "/dev/console")[.ownerAccountID] as? NSNumber
            guard console?.uint32Value == plan.userID, let user = getpwuid(plan.userID) else { throw PeerError.invalid("The requesting user must have the active graphical login session") }
            let environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "HOME":String(cString: user.pointee.pw_dir),
                "USER":String(cString: user.pointee.pw_name), "LOGNAME":String(cString: user.pointee.pw_name),
                "SUDO_USER":String(cString: user.pointee.pw_name), "SUDO_UID":String(plan.userID), "SUDO_GID":String(user.pointee.pw_gid), "MAS_NO_AUTO_INDEX":"1"]
            let receipt = try await perform(plan, bridge: bridge, environment: environment)
            print(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
        } catch {
            fputs("Store update did not complete: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
    static func requireRoot(_ url: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard [FileAttributeType.typeRegular, .typeDirectory].contains(a[.type] as? FileAttributeType ?? .typeUnknown),
              (a[.type] as? FileAttributeType != .typeRegular || (a[.referenceCount] as? NSNumber)?.intValue == 1),
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw PeerError.invalid("Unprotected Store helper material") }
    }
    static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try requireRoot(url)
        guard (try FileManager.default.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType == .typeDirectory else { throw PeerError.invalid("Store journal directory required") }
    }
    static func perform(_ plan: AppStoreUpdatePlan, bridge: URL, environment: [String: String]) async throws -> AppStoreUpdateReceipt {
        let fm = FileManager.default, base = URL(fileURLWithPath: "/Library/Application Support/Upovi")
        try ensureDirectory(base)
        let locks = base.appending(path: "PrivilegedInstallations"); try ensureDirectory(locks)
        let fd = open(locks.appending(path: "transaction.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeerError.unavailable("Cannot lock Store update") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        var a = stat()
        guard fstat(fd, &a) == 0, a.st_uid == 0, a.st_nlink == 1, a.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), flock(fd, LOCK_EX) == 0 else { throw PeerError.invalid("Unsafe transaction lock") }
        let directory = base.appending(path: "StoreUpdates"); try ensureDirectory(directory)
        let job = directory.appending(path: plan.id.uuidString)
        try fm.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var result = AppStoreUpdateReceipt(plan: plan, state: "preparing")
        var stage = "preflight"
        func save() throws { result.updatedAt = Date(); try JSONEncoder().encode(result).write(to: job.appending(path: "receipt.json"), options: .atomic); try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath: job.appending(path: "receipt.json").path) }
        try save()
        do {
            let target = URL(fileURLWithPath: plan.application.path)
            if let recovery = plan.receiptRecovery {
                stage = "receiptRecovery"
                let installed = try finishReceipt(plan, recovery: recovery, directory: directory, job: job)
                result.state = "installed"; result.installedApplication = installed; try save(); return result
            }
            guard let current = AppScanner.read(target) else { throw PeerError.invalid("Original store application is missing") }
            try plan.verifyCurrent(current); try BundleVerifier.checkSignature(target, like: plan.application)
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleID).contains(where: {
                $0.bundleURL?.standardizedFileURL.path == current.path
            }) else { throw PeerError.unavailable("Close the application before updating") }
            // Test the exact receipt directory before starting a potentially multi-gigabyte download.
            stage = "appManagement"
            let probe = target.appending(path: "Contents/_MASReceipt/.Upovi-write-\(UUID().uuidString)")
            try Data().write(to: probe, options: .withoutOverwriting)
            try fm.removeItem(at: probe)
            stage = "identityLookup"
            let list = try await ProcessCommand().run("/bin/launchctl", ["asuser",String(plan.userID),bridge.path,"list"], timeoutSeconds:60,
                outputFile:job.appending(path:"identityLookup.log"), environment:environment, maximumOutputBytes:2_000_000)
            let entries = try AppStoreCatalog.decode(list)
            guard entries.filter({ $0.adamID == plan.storeID }).count == 1,
                  entries.contains(where: { $0.adamID == plan.storeID && $0.matches(current) }) else { throw PeerError.invalid("Store identifier is missing or maps to another installation") }
            stage = "productLookup"
            let lookup = try await ProcessCommand().run("/bin/launchctl", ["asuser",String(plan.userID),bridge.path,"lookup",String(plan.storeID)], timeoutSeconds:60,
                outputFile:job.appending(path:"productLookup.log"), environment:environment, maximumOutputBytes:2_000_000)
            let product = try JSONDecoder().decode(StoreProduct.self, from: lookup)
            guard let arguments = try plan.updateArguments(for: product) else {
                result.state = "current"; result.installedApplication = current; try save(); return result
            }
            result.state = "updating"; try save()
            stage = "store"
            var operationError: (any Error)?
            do {
                _ = try await ProcessCommand().run("/bin/launchctl", ["asuser",String(plan.userID),bridge.path] + arguments,
                    timeoutSeconds:1800, outputFile:job.appending(path:"store.log"), environment:environment, maximumOutputBytes:2_000_000)
            } catch { operationError = error }
            stage = operationError == nil ? "verification" : "store"
            guard let installed = AppScanner.read(target) else { throw PeerError.unavailable("Store update outcome is unconfirmed; recheck sources before retrying") }
            do { try plan.verifyInstalled(installed); try BundleVerifier.checkSignature(target, like: plan.application) }
            catch { throw operationError ?? error }
            let unchanged = installed.version == plan.application.version && installed.build == plan.application.build
            if unchanged, let operationError { throw operationError }
            result.state = unchanged ? "current" : "installed"; result.installedApplication = installed; try save(); return result
        } catch {
            result.state = "failedOrUnconfirmed"
            let detail = (try? String(contentsOf: job.appending(path: stage + ".log"), encoding: .utf8))
            result.failure = .init(stage: stage, error: error, detail: detail)
            try save()
            return result
        }
    }

    private static func finishReceipt(_ plan: AppStoreUpdatePlan, recovery: StoreReceiptRecovery, directory: URL, job: URL) throws -> InstalledApp {
        let fm = FileManager.default
        let originalJob = directory.appending(path: recovery.transactionID.uuidString)
        let originalFile = originalJob.appending(path: "receipt.json")
        try requireRoot(originalJob); try requireRoot(originalFile)
        guard (try originalFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 65536 else { throw PeerError.invalid("Oversized Store journal") }
        var original = try JSONDecoder().decode(AppStoreUpdateReceipt.self, from: Data(contentsOf: originalFile))
        guard original.plan.id == recovery.transactionID, original.plan.receiptRecovery == nil,
              original.plan.application == plan.application, original.plan.storeID == plan.storeID,
              original.plan.version == plan.version, original.plan.userID == plan.userID,
              let sourcePath = original.failure?.recoverableReceiptPath(application: plan.application),
              try CanonicalFilePath.resolve(URL(fileURLWithPath: sourcePath)) == recovery.path else {
            throw PeerError.invalid("Receipt repair does not match the protected failed transaction")
        }
        let target = URL(fileURLWithPath: plan.application.path)
        guard let current = AppScanner.read(target), current.bundleID == plan.application.bundleID,
              current.teamID == plan.application.teamID, current.path == plan.application.path,
              VersionOrder.compare(current.version, plan.version) == .orderedSame,
              try CanonicalFilePath.resolve(target.appending(path: "Contents")) == target.appending(path: "Contents").path else {
            throw PeerError.invalid("The installed application no longer matches the receipt repair target")
        }
        try BundleVerifier.checkSignature(target, like: plan.application)
        let source = URL(fileURLWithPath: recovery.path)
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_000_000,
              try CanonicalFilePath.resolve(source) == source.path else { throw PeerError.invalid("Unsafe retained Store receipt") }
        let staged = job.appending(path: "RecoveredReceipt")
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 1_000_000,
              let data = try handle.read(upToCount: 1_000_001), data.count <= 1_000_000 else { throw PeerError.invalid("Unsafe retained Store receipt contents") }
        try data.write(to: staged, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if let expectedHash = recovery.sha256 {
            guard try BundleVerifier.sha256(of: staged) == expectedHash else { throw PeerError.invalid("Retained Store receipt changed") }
        }
        try StoreReceiptVerifier.validate(data, application: current)
        let receipts = target.appending(path: "Contents/_MASReceipt")
        if fm.fileExists(atPath: receipts.path) {
            guard try CanonicalFilePath.resolve(receipts) == receipts.path,
                  (try fm.attributesOfItem(atPath: receipts.path))[.type] as? FileAttributeType == .typeDirectory else { throw PeerError.invalid("Linked Store receipt directory") }
        } else {
            try fm.createDirectory(at: receipts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        let receiptFile = receipts.appending(path: "receipt")
        if fm.fileExists(atPath: receiptFile.path) {
            guard try CanonicalFilePath.resolve(receiptFile) == receiptFile.path else { throw PeerError.invalid("Linked Store receipt") }
            try StoreReceiptVerifier.validate(Data(contentsOf: receiptFile), application: current)
        } else {
            try data.write(to: receiptFile, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receiptFile.path)
        }
        guard let installed = AppScanner.read(target) else { throw PeerError.invalid("Receipt repair result is missing") }
        try plan.verifyInstalled(installed)
        try BundleVerifier.checkSignature(target, like: plan.application)
        original.state = "installed"; original.installedApplication = installed; original.failure = nil; original.updatedAt = Date()
        try JSONEncoder().encode(original).write(to: originalFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalFile.path)
        return installed
    }
}
