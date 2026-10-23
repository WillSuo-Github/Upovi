import Foundation

public struct InstalledApp: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let path: String
    public let teamID: String?
    public let isAppStore: Bool
    public let feedURL: URL?

    public init(name: String, bundleID: String, version: String, build: String = "", path: String,
                teamID: String? = nil, isAppStore: Bool = false, feedURL: URL? = nil) {
        self.name = name; self.bundleID = bundleID; self.version = version; self.build = build
        self.path = path; self.teamID = teamID; self.isAppStore = isAppStore; self.feedURL = feedURL
    }

    public var channel: String { isAppStore ? "app-store" : "developer" }
}

public struct UpdateCandidate: Identifiable, Hashable, Sendable {
    public var id: String { source + version + build }
    public let version: String
    public var build: String = ""
    public let source: String
    public let isCommunity: Bool
    public let url: URL?
    public var usesBuildVersion: Bool = false
    public var observedAt: Date = Date()
    public var peerID: String? = nil
    public var expiresAt: Date? = nil
    public var download: DownloadDescriptor? = nil

    public init(version: String, build: String = "", source: String, isCommunity: Bool, url: URL?, usesBuildVersion: Bool = false,
                observedAt: Date = Date(), peerID: String? = nil, expiresAt: Date? = nil, download: DownloadDescriptor? = nil) {
        self.version = version; self.build = build; self.source = source; self.isCommunity = isCommunity; self.url = url
        self.usesBuildVersion = usesBuildVersion; self.observedAt = observedAt; self.peerID = peerID
        self.expiresAt = expiresAt; self.download = isCommunity ? nil : download
    }
}
