import Foundation
@testable import UpoviCore

// Developer-only read-only HTTPS acceptance. Never scans or mutates installed apps.
actor SourceRequests {
    struct Event: Codable { let host: String; let status: Int; let conditional: Bool; let bytes: Int }
    private(set) var events: [Event] = []
    func fetch(_ url: URL, limit: Int, headers: [String: String]) async throws -> HTTPMetadataResponse {
        let response = try await HTTPTransfer.metadata(from: url, limit: limit, headers: headers)
        events.append(.init(host: url.host ?? "", status: response.status,
                            conditional: headers["If-None-Match"] != nil || headers["If-Modified-Since"] != nil, bytes: response.data.count))
        return response
    }
}
@main struct SourceRefreshAcceptance {
    static func main() async throws {
        let requests = SourceRequests()
        let client = SourceHTTPClient(transport: { try await requests.fetch($0, limit: $1, headers: $2) })
        let catalogURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
        let catalog = CaskCatalog(fetch: { try await client.data(from: catalogURL, limit: 40_000_000) })
        let first = try await catalog.metadata(for: InstalledApp(name: "Synthetic", bundleID: "com.github.GitHubClient", version: "0", path: "/synthetic/GitHub Desktop.app"))
        guard first != nil else { throw PeerError.invalid("Expected exact official catalog mapping") }
        _ = try await catalog.metadata(for: "com.github.GitHubClient")
        let beforeRefresh = await requests.events.count
        await client.revalidate(); await catalog.invalidate()
        let fresh = try await catalog.metadata(for: InstalledApp(name: "Synthetic", bundleID: "com.github.GitHubClient", version: "0", path: "/synthetic/GitHub Desktop.app"))
        let afterRefresh = await requests.events.count
        guard fresh != nil, beforeRefresh == 1, afterRefresh == 2 else { throw PeerError.invalid("Manual refresh did not contact the origin") }
        let releaseURL = URL(string: "https://api.github.com/repos/WillSuo-Github/livehub-desktop/releases/latest")!
        _ = try await client.data(from: releaseURL, limit: 3_000_000)
        await client.revalidate()
        _ = try await client.data(from: releaseURL, limit: 3_000_000)
        let events = await requests.events
        guard events.count == 4, events[1].conditional, events[3].conditional else { throw PeerError.invalid("Expected conditional revalidation") }
        struct Result: Codable { let result: String; let manualCatalogRefreshContactedOrigin: Bool; let requests: [SourceRequests.Event] }
        print(String(decoding: try JSONEncoder().encode(Result(result: "passed", manualCatalogRefreshContactedOrigin: true, requests: events)), as: UTF8.self))
    }
}
