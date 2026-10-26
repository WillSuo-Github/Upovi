import Foundation

public struct CaskMetadata: Decodable, Sendable {
    public let token: String
    public let version: String
    public let url: URL?
    public let sha256: String?
    public let disabled: Bool?
    public let artifacts: [Artifact]?
    public let variations: [String: Variation]?
    public struct Variation: Decodable, Sendable {
        let version: String?
        let url: URL?
        let sha256: String?
        let artifacts: [Artifact]?
    }
    public struct Artifact: Decodable, Sendable {
        let app: [String]?
        let uninstall: [Uninstall]?
        enum CodingKeys: String, CodingKey { case app, uninstall, target }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let values = try? c.decode([AppValue].self, forKey: .app) {
                var names = values.compactMap(\.name)
                if let target = try? c.decode(String.self, forKey: .target), !names.isEmpty { names.append(target) }
                app = Array(Set(names.compactMap(Self.applicationName))).sorted()
            } else { app = nil }
            uninstall = try c.decodeIfPresent([Uninstall].self, forKey: .uninstall)
        }
        private struct AppValue: Decodable {
            let name: String?
            enum CodingKeys: String, CodingKey { case target }
            init(from decoder: any Decoder) throws {
                if let string = try? decoder.singleValueContainer().decode(String.self) { name = string }
                else { name = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .target) }
            }
        }
        private static func applicationName(_ value: String) -> String? {
            let path = value.hasPrefix("/Applications/") ? String(value.dropFirst("/Applications/".count)) : value
            guard path.hasSuffix(".app"), !path.contains("/"), !path.contains("\\"), !path.contains(".."),
                  !path.contains(where: { "*?[]".contains($0) || $0.isNewline }) else { return nil }
            return path
        }
        struct Uninstall: Decodable, Sendable {
            let quit: [String]
            enum CodingKeys: String, CodingKey { case quit }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let value = try? c.decode(String.self, forKey: .quit) { quit = [value] }
                else { quit = (try? c.decode([String].self, forKey: .quit)) ?? [] }
            }
        }
    }
    public var applicationNames: [String] { (artifacts ?? []).flatMap { $0.app ?? [] } }
    public func platformVersion(intel: Bool, osMajor: Int) -> String {
        variation(intel: intel, osMajor: osMajor)?.version ?? version
    }
    private func variation(intel: Bool, osMajor: Int) -> Variation? {
        let names = [11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate"]
        guard let name = names[osMajor] else { return nil }
        return variations?[intel ? name : "arm64_" + name]
    }
    public var currentVersion: String {
        #if arch(x86_64)
        return platformVersion(intel: true, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #else
        return platformVersion(intel: false, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #endif
    }
    public var bundleIDs: [String] {
        (artifacts ?? []).flatMap { ($0.uninstall ?? []).flatMap(\.quit) }
            .filter { !$0.isEmpty && !$0.contains(where: { "*?[]/ ".contains($0) }) }
    }
    public var download: DownloadDescriptor? {
        #if arch(x86_64)
        return download(intel: true, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #else
        return download(intel: false, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #endif
    }
    public func download(intel: Bool, osMajor: Int) -> DownloadDescriptor? {
        let selected = variation(intel: intel, osMajor: osMajor)
        // The selected platform's artifacts decide whether a DMG/ZIP contains a direct app.
        let directApp = (selected?.artifacts ?? artifacts ?? []).contains(where: { !($0.app ?? []).isEmpty })
        guard let url = selected?.url ?? url, url.scheme == "https", let sha256 = selected?.sha256 ?? sha256, sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              ["zip", "dmg", "pkg"].contains(url.pathExtension.lowercased()),
              directApp || url.pathExtension.lowercased() == "pkg" else { return nil }
        return .init(url: url, sha256: sha256)
    }
}

/// Match only exact bundle IDs explicitly declared in official cask metadata.
public actor CaskCatalog {
    public static let shared = CaskCatalog()
    private var pending: (id: UUID, task: Task<[CaskMetadata], any Error>)?
    private var cache: [String: CaskMetadata] = [:]
    private var catalog: [CaskMetadata] = []
    private var loadedAt: Date?
    private var failedAt: Date?
    private let fetch: @Sendable () async throws -> Data
    public init() {
        fetch = { try await UpdateChecker.fetch(URL(string: "https://formulae.brew.sh/api/cask.json")!, limit: 40_000_000) }
    }
    init(fetch: @escaping @Sendable () async throws -> Data) { self.fetch = fetch }

    public func invalidate() {
        loadedAt = nil; failedAt = nil
        // An older in-flight response cannot populate a newer refresh generation.
        pending = nil
    }

    // Explicit identities checked against the official cask's declared application and identity paths.
    // These are never inferred from a display-name search or a peer report.
    public static let curated: [String: String] = [
        "com.vscodium": "vscodium",
        "org.blenderfoundation.blender": "blender",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.github.GitHubClient": "github",
        "com.github.githubapp": "github-copilot-app",
        "com.bjango.istatmenus": "istat-menus",
        "com.janhuelsmann.SaneSideButtons": "sanesidebuttons",
        "com.yetone.magpie": "magpie",
        "com.soda.music": "sodamusic",
        "org.pqrs.Karabiner-Elements.Settings": "karabiner-elements",
        "org.pqrs.Karabiner-EventViewer": "karabiner-elements",
        "wang.jianing.app.OpenInTerminal": "openinterminal",
        "us.zoom.xos": "zoom"
    ]

    public static func resolve(_ app: InstalledApp, in casks: [CaskMetadata]) -> CaskMetadata? {
        let eligible = casks.filter { $0.disabled != true && !$0.token.contains("@") }
        if let token = curated[app.bundleID] { return eligible.first { $0.token == token } }
        let matches = eligible.filter { $0.bundleIDs.contains(app.bundleID) }
        if matches.count == 1 { return matches[0] }
        // Some vendors reuse an identifier across product names; require an exact declared bundle filename.
        let filename = URL(fileURLWithPath: app.path).lastPathComponent
        let named = matches.filter { $0.applicationNames.contains(filename) }
        return named.count == 1 ? named[0] : nil
    }

    public static func index(_ casks: [CaskMetadata]) -> [String: CaskMetadata] {
        var result: [String: CaskMetadata] = [:], ambiguous = Set<String>()
        for cask in casks where cask.disabled != true && !cask.token.contains("@") {
            for bundle in cask.bundleIDs {
                if let previous = result[bundle], previous.token != cask.token { ambiguous.insert(bundle) }
                else { result[bundle] = cask }
            }
        }
        return result.filter { !ambiguous.contains($0.key) }
    }

    public func metadata(for bundle: String) async throws -> CaskMetadata? {
        try await load()
        return cache[bundle]
    }

    public func metadata(for app: InstalledApp) async throws -> CaskMetadata? {
        try await load()
        return Self.resolve(app, in: catalog)
    }

    private func load() async throws {
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { throw PeerError.unavailable("Homebrew catalog temporarily unavailable") }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        try Task.checkCancellation()
        let request: (id: UUID, task: Task<[CaskMetadata], any Error>)
        if let pending { request = pending }
        else {
            let fetch = fetch
            request = (UUID(), Task {
                try JSONDecoder().decode([CaskMetadata].self, from: await fetch())
            })
            pending = request
        }
        do {
            let result = try await request.task.value
            try Task.checkCancellation()
            guard pending?.id == request.id else { try await load(); return }
            catalog = result; cache = Self.index(result); loadedAt = Date(); pending = nil; failedAt = nil
        } catch {
            if pending?.id == request.id { pending = nil; failedAt = error is CancellationError ? nil : Date() }
            throw error
        }
    }
}
