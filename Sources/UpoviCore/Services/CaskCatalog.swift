import Foundation

public struct CaskMetadata: Decodable, Sendable {
    public let token: String
    public let version: String
    public let url: URL?
    public let sha256: String?
    public let disabled: Bool?
    public let artifacts: [Artifact]?
    public struct Artifact: Decodable, Sendable {
        let uninstall: [Uninstall]?
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
    public var bundleIDs: [String] {
        (artifacts ?? []).flatMap { ($0.uninstall ?? []).flatMap(\.quit) }
            .filter { !$0.isEmpty && !$0.contains(where: { "*?[]/ ".contains($0) }) }
    }
    public var download: DownloadDescriptor? {
        guard let url, url.scheme == "https", let sha256, sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              ["zip", "dmg"].contains(url.pathExtension.lowercased()) else { return nil }
        return .init(url: url, sha256: sha256)
    }
}

/// Match only exact bundle IDs explicitly declared in official cask metadata.
public actor CaskCatalog {
    public static let shared = CaskCatalog()
    private var pending: Task<[String: CaskMetadata], any Error>?
    private var cache: [String: CaskMetadata] = [:]
    private var loadedAt: Date?
    private var failedAt: Date?
    public init() { }

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
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { throw PeerError.unavailable("Homebrew catalog temporarily unavailable") }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 86400 { return cache[bundle] }
        let task: Task<[String: CaskMetadata], any Error>
        if let pending { task = pending }
        else {
            task = Task {
                let data = try await UpdateChecker.fetch(URL(string: "https://formulae.brew.sh/api/cask.json")!, limit: 40_000_000)
                return Self.index(try JSONDecoder().decode([CaskMetadata].self, from: data))
            }
            pending = task
        }
        do {
            let result = try await task.value
            cache = result; loadedAt = Date(); pending = nil
            return result[bundle]
        } catch { pending = nil; failedAt = Date(); throw error }
    }
}
