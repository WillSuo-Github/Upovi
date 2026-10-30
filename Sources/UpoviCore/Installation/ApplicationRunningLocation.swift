import Darwin
import Foundation

public enum ApplicationRunningLocation {
    /// App Translocation changes bundleURL, but the read-only nullfs mount retains its original source.
    public static func matches(_ runtime: URL, installedPath: String) -> Bool {
        let path = runtime.standardizedFileURL.path
        if path == URL(fileURLWithPath: installedPath).standardizedFileURL.path { return true }
        guard path.contains("/AppTranslocation/") else { return false }
        var volume = statfs()
        guard statfs(runtime.path, &volume) == 0 else { return false }
        let type = withUnsafePointer(to: &volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let source = withUnsafePointer(to: &volume.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let mount = withUnsafePointer(to: &volume.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return matchesTranslocation(runtimePath: path, installedPath: installedPath, source: source,
                                    mount: mount, fileSystem: type, readOnly: volume.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    static func matchesTranslocation(runtimePath: String, installedPath: String, source: String,
                                    mount: String, fileSystem: String, readOnly: Bool) -> Bool {
        let original = URL(fileURLWithPath: source).standardizedFileURL
        let mounted = URL(fileURLWithPath: mount).standardizedFileURL
        guard readOnly, fileSystem == "nullfs", mount.contains("/AppTranslocation/"), original.pathExtension == "app",
              original.path == URL(fileURLWithPath: installedPath).standardizedFileURL.path else { return false }
        return URL(fileURLWithPath: runtimePath).standardizedFileURL.path ==
            mounted.appending(path: "d").appending(path: original.lastPathComponent).path
    }
}
