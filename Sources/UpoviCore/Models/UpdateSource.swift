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
    /// A signature-only download remains unverified until the extracted app passes the installer checks.
    public func canVerify(for app: InstalledApp) -> Bool {
        hasIntegrityProof || (sha256 == nil && edSignature == nil &&
            ApplicationSourceCatalog.permitsDeveloperDownload(url, for: app))
    }
}
