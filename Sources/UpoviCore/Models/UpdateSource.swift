import Foundation

public enum SourceStatus: String, Codable, Sendable {
    case updates, current, unsupported, partial, failed, appStore
}

public struct SourceOverride: Codable, Sendable {
    public var appcast: URL?
    public var githubRepository: String?
    public init(appcast: URL? = nil, githubRepository: String? = nil) {
        self.appcast = appcast; self.githubRepository = githubRepository
    }
}

public struct DownloadDescriptor: Hashable, Codable, Sendable {
    public let url: URL
    public let sha256: String?
    public let edSignature: Data?
    public init(url: URL, sha256: String? = nil, edSignature: Data? = nil) {
        self.url = url; self.sha256 = sha256; self.edSignature = edSignature
    }
    public var hasIntegrityProof: Bool {
        sha256.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } == true || edSignature?.count == 64
    }
    /// The format named by the URL, or nil when it must be read from the verified bytes instead.
    public var declaredFormat: String? {
        let ext = url.pathExtension.lowercased()
        return ["zip", "dmg", "pkg"].contains(ext) ? ext : nil
    }
    /// Extensionless or query URLs (.../stable, ?version=) may still serve a ZIP or DMG.
    /// Known unsupported archive types are refused before download.
    public var formatResolvableAfterDownload: Bool {
        declaredFormat == nil && !["gz", "tgz", "xz", "bz2", "tbz", "tar", "7z", "rar", "zst", "lz", "lzma", "exe", "msi", "app"]
            .contains(url.pathExtension.lowercased())
    }
    /// Identify a downloaded ZIP, DMG or flat PKG from its contents. Call only after the archive proof passed.
    public static func sniffFormat(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        if head == Data([0x50, 0x4b, 0x03, 0x04]) || head == Data([0x50, 0x4b, 0x05, 0x06]) { return "zip" }
        if head == Data("xar!".utf8) { return "pkg" }
        // UDIF images end with a 512-byte "koly" trailer.
        guard let size = try? handle.seekToEnd(), size >= 512 else { return nil }
        try? handle.seek(toOffset: size - 512)
        return (try? handle.read(upToCount: 4)) == Data("koly".utf8) ? "dmg" : nil
    }
    /// A signature-only download remains unverified until the extracted app passes the installer checks.
    public func canVerify(for app: InstalledApp) -> Bool {
        hasIntegrityProof || (sha256 == nil && edSignature == nil &&
            ApplicationSourceCatalog.permitsDeveloperDownload(url, for: app))
    }
}
