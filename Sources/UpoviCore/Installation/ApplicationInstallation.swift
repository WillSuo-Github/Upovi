import Darwin
import Foundation

/// Completes a user-requested installation only after identity and Gatekeeper approval.
public enum ApplicationInstallation {
    public static func finalize(_ bundle: URL, matching expected: InstalledApp) async throws {
        try await finalize(bundle, validate: { url in
            guard let app = AppScanner.read(url), !app.isAppStore, !expected.isAppStore,
                  app.bundleID == expected.bundleID, app.teamID == expected.teamID,
                  app.version == expected.version, app.build == expected.build else {
                throw PeerError.invalid("Application changed before installation finalization")
            }
            try BundleVerifier.checkDeveloperIDSignature(url, like: expected)
        }, assess: { url in
            try await assess(url)
        })
    }

    static func assess(_ bundle: URL) async throws {
        do {
            _ = try await ProcessCommand().run("/usr/sbin/spctl", ["--assess", "--type", "execute", bundle.path])
        } catch is CancellationError { throw CancellationError() }
        catch { throw PeerError.invalid(String(localized: "macOS 安全检查未批准此更新。请使用官方更新器；若当前离线，请联网后重试。")) }
    }

    static func finalize(_ bundle: URL, validate: @Sendable (URL) throws -> Void,
                         assess: @Sendable (URL) async throws -> Void) async throws {
        guard bundle.pathExtension == "app",
              try FileManager.default.attributesOfItem(atPath: bundle.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw PeerError.invalid("An unlinked application directory is required")
        }
        try validate(bundle)
        try await assess(bundle)
        try Task.checkCancellation()
        try validate(bundle)
        let canonical = try CanonicalFilePath.resolve(bundle)
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var root = stat()
        guard fstat(descriptor, &root) == 0 else { throw posixError() }
        try releaseQuarantine(descriptor, device: root.st_dev, depth: 0)
        try validate(bundle)
        try verifyFinalized(bundle)
    }

    /// Copying/activating a prepared application must not reintroduce download isolation.
    public static func verifyFinalized(_ bundle: URL) throws {
        let result = getxattr(bundle.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard result < 0, errno == ENOATTR else {
            throw PeerError.invalid("Application installation still has download quarantine")
        }
    }

    // Descriptor-relative traversal never follows symlinks or touches another volume or hard-linked file.
    // Only quarantine is removed; provenance, permissions, Finder tags and all other metadata stay intact.
    private static func releaseQuarantine(_ descriptor: Int32, device: dev_t, depth: Int) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        let type = info.st_mode & S_IFMT
        guard depth <= 128, info.st_dev == device,
              type == S_IFDIR || (type == S_IFREG && info.st_nlink == 1) else {
            throw PeerError.invalid("Unsafe application entry during installation finalization")
        }
        if type == S_IFDIR {
            let copy = dup(descriptor)
            guard copy >= 0 else { throw posixError() }
            guard let directory = fdopendir(copy) else { close(copy); throw posixError() }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw posixError() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var before = stat()
                guard fstatat(descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
                if before.st_mode & S_IFMT == S_IFLNK { continue }
                guard [S_IFREG, S_IFDIR].contains(before.st_mode & S_IFMT) else {
                    throw PeerError.invalid("Unsupported application entry during installation finalization")
                }
                let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard child >= 0 else { throw posixError() }
                do {
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else {
                        throw PeerError.invalid("Application entry changed during installation finalization")
                    }
                    try releaseQuarantine(child, device: device, depth: depth + 1)
                }
            }
        }
        // Clear the directory last, so an incomplete traversal retains its isolation marker.
        // Even removing an absent xattr can be denied on protected vendor files.
        // Do not request a write unless there is actually quarantine to release.
        let quarantine = fgetxattr(descriptor, "com.apple.quarantine", nil, 0, 0, 0)
        if quarantine < 0 {
            guard errno == ENOATTR else { throw posixError() }
            return
        }
        if fremovexattr(descriptor, "com.apple.quarantine", 0) != 0, errno != ENOATTR { throw posixError() }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
