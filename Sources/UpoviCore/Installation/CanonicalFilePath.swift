import Darwin
import Foundation

/// Resolve actual filesystem links without Foundation's /private/var to /var alias shortening.
public enum CanonicalFilePath {
    public static func resolve(_ url: URL) throws -> String {
        let pointer = url.withUnsafeFileSystemRepresentation { path in
            path.flatMap { realpath($0, nil) }
        }
        guard let pointer else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
