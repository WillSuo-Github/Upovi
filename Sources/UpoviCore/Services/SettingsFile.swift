import Foundation

/// A small atomic property-list store, independent of the preferences daemon.
public struct SettingsFile: Sendable {
    public let url: URL
    private static let maximumBytes = 4_000_000
    public init(url: URL) { self.url = url }

    public func read() throws -> [String: Any]? {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return nil }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, let size = attributes.fileSize, size <= Self.maximumBytes else {
            throw PeerError.invalid("Settings file is linked or exceeds its size limit")
        }
        let data = try Data(contentsOf: url)
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw PeerError.invalid("Settings file is not a property-list dictionary")
        }
        return result
    }

    public func write(_ values: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        guard data.count <= Self.maximumBytes else { throw PeerError.invalid("Settings exceed their size limit") }
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        if files.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw PeerError.invalid("Refusing to replace linked settings")
        }
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
