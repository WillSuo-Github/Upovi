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
        let zap: [Zap]?
        enum CodingKeys: String, CodingKey { case app, uninstall, target, zap }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let values = try? c.decode([AppValue].self, forKey: .app) {
                var names = values.compactMap(\.name)
                if let target = try? c.decode(String.self, forKey: .target), !names.isEmpty { names.append(target) }
                app = Array(Set(names.compactMap(Self.applicationName))).sorted()
            } else { app = nil }
            uninstall = try c.decodeIfPresent([Uninstall].self, forKey: .uninstall)
            zap = try? c.decode([Zap].self, forKey: .zap)
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
        struct Zap: Decodable, Sendable {
            let trash: [String]
            enum CodingKeys: String, CodingKey { case trash }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let value = try? c.decode(String.self, forKey: .trash) { trash = value.count <= 1024 ? [value] : [] }
                else {
                    let values = (try? c.decode([String].self, forKey: .trash)) ?? []
                    trash = values.count <= 256 ? values.filter { $0.count <= 1024 } : []
                }
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
    /// Exact identifiers in declared per-user identity paths are additional source references,
    /// not trusted publisher identities. Resolution also requires the exact main app filename;
    /// installation still verifies the real incoming bundle ID, Apple Developer ID and payload.
    public var bundleIdentityReferences: [String] {
        let rules = [("~/Library/Preferences/", ".plist"), ("~/Library/Caches/", ""),
                     ("~/Library/Saved Application State/", ".savedState"), ("~/Library/Containers/", ""),
                     ("~/Library/Application Scripts/", "")]
        let paths = (artifacts ?? []).flatMap { ($0.zap ?? []).flatMap(\.trash) }
        return Array(Set(paths.compactMap { path -> String? in
            for (prefix, suffix) in rules where path.hasPrefix(prefix) && path.hasSuffix(suffix) {
                let identifier = String(path.dropFirst(prefix.count).dropLast(suffix.count))
                guard !identifier.isEmpty, identifier.count <= 255,
                      identifier.first.map({ $0.isLetter || $0.isNumber }) == true,
                      identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                      !identifier.contains("..") else { return nil }
                return identifier
            }
            return nil
        })).sorted()
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
              directApp || url.pathExtension.lowercased() == "pkg" else { return nil }
        let descriptor = DownloadDescriptor(url: url, sha256: sha256)
        // Without an extension, only a direct-app cask may defer to the verified bytes (ZIP or DMG).
        guard descriptor.declaredFormat != nil || (directApp && descriptor.formatResolvableAfterDownload) else { return nil }
        return descriptor
    }

    public func download(for app: InstalledApp) -> DownloadDescriptor? {
        if let download { return download }
        #if arch(x86_64)
        let intel = true
        #else
        let intel = false
        #endif
        let selected = variation(intel: intel, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        let proof = selected?.sha256 ?? sha256
        guard proof == nil || proof == "no_check",
              (selected?.artifacts ?? artifacts ?? []).contains(where: { !($0.app ?? []).isEmpty }),
              let url = selected?.url ?? url,
              ApplicationSourceCatalog.permitsDeveloperDownload(url, for: app) else { return nil }
        return .init(url: url)
    }
}

/// Match exact identifiers explicitly declared in official cask metadata. Identity-path references
/// require an exact application filename and never become installer trust anchors.
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
    public static let curated = ApplicationSourceCatalog.catalogExceptions

    public static func resolve(_ app: InstalledApp, in casks: [CaskMetadata]) -> CaskMetadata? {
        let eligible = casks.filter { $0.disabled != true && !$0.token.contains("@") }
        if let token = curated[app.bundleID] { return eligible.first { $0.token == token } }
        let matches = eligible.filter { $0.bundleIDs.contains(app.bundleID) }
        if matches.count == 1 { return matches[0] }
        // Some vendors reuse an identifier across product names; require an exact declared bundle filename.
        let filename = URL(fileURLWithPath: app.path).lastPathComponent
        let named = matches.filter { $0.applicationNames.contains(filename) }
        if !matches.isEmpty { return named.count == 1 ? named[0] : nil }
        let referenced = eligible.filter { $0.applicationNames.contains(filename) && $0.bundleIdentityReferences.contains(app.bundleID) }
        guard referenced.count == 1 else { return nil }
        UpoviLog.sources.info("event=source.catalogIdentityPathMatched \(UpoviDiagnosticContext.application(app)) match=exactIdentityPathAndFilename")
        return referenced[0]
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
