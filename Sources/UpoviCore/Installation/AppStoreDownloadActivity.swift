import Darwin
import Foundation
import os

/// Read only the size and allocated blocks of packages for the selected Store product.
public struct AppStoreDownloadActivity: Sendable {
    private struct Package: Sendable {
        let inode: ino_t
        let size: off_t
        let blocks: blkcnt_t
    }

    private let cacheRoot: String
    private let directories: [String]
    private let userID: uid_t
    private let previous: OSAllocatedUnfairLock<[String: Package]>

    public init?(darwinUserCacheDirectory: String, storeID: UInt64, userID: uid_t) {
        let path = darwinUserCacheDirectory.hasPrefix("/private/") ? String(darwinUserCacheDirectory.dropFirst(8)) : darwinUserCacheDirectory
        guard path.range(of: #"\A/var/folders/[a-z0-9_]{2}/[a-z0-9_]{1,64}/C/?\z"#, options: .regularExpression) != nil else { return nil }
        let components = path.split(separator: "/").dropFirst(2).map(String.init)
        self.init(cacheRoot: "/private/var/folders", cacheDirectories: components, storeID: storeID, userID: userID)
    }

    init(cacheRoot: String, cacheDirectories: [String] = [], storeID: UInt64, userID: uid_t) {
        self.cacheRoot = cacheRoot
        directories = cacheDirectories + ["com.apple.appstore", String(storeID)]
        self.userID = userID
        previous = OSAllocatedUnfairLock(initialState: Self.packages(in: cacheRoot, directories: directories, userID: userID))
    }

    public func hasAdvanced() -> Bool {
        let current = Self.packages(in: cacheRoot, directories: directories, userID: userID)
        return previous.withLock { previous in
            defer { previous = current }
            return current.contains { name, package in
                guard let old = previous[name], old.inode == package.inode else { return package.size > 0 }
                return package.size > old.size || package.blocks > old.blocks
            }
        }
    }

    private static func packages(in root: String, directories: [String], userID: uid_t) -> [String: Package] {
        // Cache contents belong to the login user. Do not follow links or open any package as root.
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open(root, flags)
        for component in directories {
            guard descriptor >= 0 else { return [:] }
            let child = openat(descriptor, component, flags)
            close(descriptor)
            descriptor = child
        }
        guard descriptor >= 0 else { return [:] }
        guard let entries = fdopendir(descriptor) else { close(descriptor); return [:] }
        defer { closedir(entries) }

        var packages: [String: Package] = [:]
        for _ in 0..<256 {
            guard let entry = readdir(entries) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".pkg") else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == userID else { continue }
            packages[name] = Package(inode: info.st_ino, size: info.st_size, blocks: info.st_blocks)
        }
        return packages
    }
}
