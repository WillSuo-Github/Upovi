import CryptoKit
import Darwin
import Foundation

public enum ArtifactDownloadPhase: Sendable { case downloading, verifying }

/// Private, resumable artifact storage. Every use revalidates the selected integrity proof.
public actor ArtifactDownloadCache {
    public static let shared = ArtifactDownloadCache()
    private let directory: URL
    private let configuration: URLSessionConfiguration
    private var busy = Set<String>()
    public init(directory: URL = URL.cachesDirectory.appending(path: "Upovi/Downloads")) {
        self.directory = directory.standardizedFileURL; configuration = .ephemeral
    }
    init(directory: URL, configuration: URLSessionConfiguration) {
        self.directory = directory.standardizedFileURL; self.configuration = configuration.copy() as! URLSessionConfiguration
    }
    static func key(_ descriptor: DownloadDescriptor) -> String {
        let identity = descriptor.url.absoluteString + "|" + (descriptor.sha256 ?? "") + "|" + (descriptor.edSignature?.base64EncodedString() ?? "")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func ensureDirectory(_ url: URL) throws {
        let files = FileManager.default
        guard url.resolvingSymlinksInPath().path == url.path else { throw PeerError.invalid("Linked download cache directory") }
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let a = try files.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory, (a[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw PeerError.invalid("Unsafe download cache owner or type")
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func lockEntry(_ key: String) throws -> Int32 {
        let locks = directory.appending(path: ".locks"); try ensureDirectory(locks)
        let fd = open(locks.appending(path: key).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeerError.unavailable("Cannot lock the download cache") }
        var a = stat()
        guard fstat(fd, &a) == 0, a.st_uid == geteuid(), a.st_nlink == 1,
              a.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw PeerError.unavailable("This artifact is already being downloaded")
        }
        return fd
    }
    private func unlock(_ fd: Int32) { _ = flock(fd, LOCK_UN); close(fd) }
    public func download(_ descriptor: DownloadDescriptor, app: InstalledApp, to destination: URL,
                         onPhase: @escaping @Sendable (ArtifactDownloadPhase) -> Void = { _ in },
                         onResume: @escaping @Sendable (Int64) -> Void = { _ in },
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard descriptor.canVerify(for: app), descriptor.url.scheme == "https", descriptor.url.host != nil,
              descriptor.url.user == nil, descriptor.url.password == nil else { throw PeerError.invalid("A verified HTTPS download is required") }
        try Task.checkCancellation()
        try ensureDirectory(directory)
        let key = Self.key(descriptor)
        guard busy.insert(key).inserted else { throw PeerError.unavailable("This artifact is already being downloaded") }
        defer { busy.remove(key) }
        let fd = try lockEntry(key); defer { unlock(fd) }
        let entry = directory.appending(path: key); try ensureDirectory(entry)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
        try prune()
        let partial = entry.appending(path: "Download.part"), complete = entry.appending(path: "Complete.bin")
        if descriptor.hasIntegrityProof, FileManager.default.fileExists(atPath: complete.path) {
            onPhase(.verifying)
            var verified = false
            do {
                try await verify(complete, descriptor: descriptor, app: app)
                verified = true
            } catch is CancellationError { throw CancellationError() }
            catch { try FileManager.default.removeItem(at: complete) }
            if verified {
                try FileManager.default.copyItem(at: complete, to: destination)
                let size = (try? complete.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                progress(Int64(size), Int64(size)); return
            }
        }
        onPhase(.downloading)
        try await HTTPTransfer.download(from: descriptor.url, to: partial, limit: 2_000_000_000, resuming: true,
                                        configuration: configuration, onResume: onResume, progress: progress)
        onPhase(.verifying)
        do { try await verify(partial, descriptor: descriptor, app: app) }
        catch {
            if !Task.isCancelled { try? FileManager.default.removeItem(at: partial); try? FileManager.default.removeItem(at: DownloadResumeState.metadata(for: partial)) }
            throw error
        }
        try Task.checkCancellation()
        // Signature-only downloads cannot be treated as verified archive cache entries.
        if !descriptor.hasIntegrityProof {
            try FileManager.default.moveItem(at: partial, to: destination)
            try? FileManager.default.removeItem(at: DownloadResumeState.metadata(for: partial))
            return
        }
        try FileManager.default.moveItem(at: partial, to: complete)
        try? FileManager.default.removeItem(at: DownloadResumeState.metadata(for: partial))
        try FileManager.default.copyItem(at: complete, to: destination)
    }
    private func verify(_ file: URL, descriptor: DownloadDescriptor, app: InstalledApp) async throws {
        let a = try FileManager.default.attributesOfItem(atPath: file.path)
        guard a[.type] as? FileAttributeType == .typeRegular, (a[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (a[.referenceCount] as? NSNumber)?.intValue == 1, (a[.size] as? NSNumber)?.int64Value ?? Int64.max <= 2_000_000_000 else {
            throw PeerError.invalid("Unsafe cached artifact")
        }
        let work = Task.detached { try BundleVerifier.validateDownload(file, descriptor: descriptor, app: app) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
    }
    /// Old/inactive entries only. Stable zero-byte lock files are kept to prevent cross-process races.
    public func prune() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try ensureDirectory(directory)
        let files = FileManager.default
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        func size(_ entry: URL) -> Int64 {
            var bytes: Int64 = 0
            for name in ["Download.part", "Complete.bin"] {
                bytes += ((try? FileManager.default.attributesOfItem(atPath: entry.appending(path: name).path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return bytes
        }
        var total = entries.reduce(Int64(0)) { $0 + size($1) }
        for entry in entries where !busy.contains(entry.lastPathComponent) {
            let age = Date().timeIntervalSince((try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            guard age > 7 * 86400 || total > 4_000_000_000 else { continue }
            guard let fd = try? lockEntry(entry.lastPathComponent) else { continue }
            defer { unlock(fd) }
            let bytes = size(entry)
            try files.removeItem(at: entry); total -= bytes
        }
    }
}
