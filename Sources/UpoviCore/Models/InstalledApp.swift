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

public struct UpdateCandidate: Identifiable, Hashable, Codable, Sendable {
    public var id: String { source + version + build }
    public let version: String
    public var build: String = ""
    public let source: String
    public let isCommunity: Bool
    public let url: URL?
    public var usesBuildVersion: Bool = false
    /// Sparkle's machine version orders releases even when a separate display version exists.
    /// Optional for backwards-compatible decoding of existing batch history.
    public var buildIsAuthoritative: Bool? = nil
    public var observedAt: Date = Date()
    public var peerID: String? = nil
    public var expiresAt: Date? = nil
    public var download: DownloadDescriptor? = nil
    public var releaseNotes: String? = nil
    public var appStoreID: UInt64? = nil
    public var storeReceiptRecovery: StoreReceiptRecovery? = nil

    public init(version: String, build: String = "", source: String, isCommunity: Bool, url: URL?, usesBuildVersion: Bool = false,
                observedAt: Date = Date(), peerID: String? = nil, expiresAt: Date? = nil, download: DownloadDescriptor? = nil, releaseNotes: String? = nil, appStoreID: UInt64? = nil,
                buildIsAuthoritative: Bool? = nil) {
        self.version = version; self.build = build; self.source = source; self.isCommunity = isCommunity; self.url = url
        self.usesBuildVersion = usesBuildVersion; self.observedAt = observedAt; self.peerID = peerID
        self.expiresAt = expiresAt; self.download = isCommunity ? nil : download
        self.releaseNotes = isCommunity ? nil : releaseNotes.map { String($0.prefix(20_000)) }
        self.appStoreID = isCommunity ? nil : appStoreID
        self.buildIsAuthoritative = isCommunity ? nil : buildIsAuthoritative
    }

    public var comparesUsingBuild: Bool { usesBuildVersion || buildIsAuthoritative == true }
    public func isNewer(than app: InstalledApp) -> Bool {
        comparesUsingBuild
            ? !app.build.isEmpty && VersionOrder.compare(build, app.build) == .orderedDescending
            : VersionOrder.isNewer(version: version, build: build, than: app)
    }
}
