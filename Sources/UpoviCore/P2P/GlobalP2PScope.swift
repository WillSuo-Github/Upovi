import Foundation

public struct P2PSyncBatch: Sendable {
    public let apps: [InstalledApp]
    public let start: Int
    public let total: Int
    public let nextOffset: Int
}

public enum GlobalP2PScope {
    public static let batchSize = 20

    public static func applications(_ apps: [InstalledApp]) -> [InstalledApp] {
        var topics: [Data: InstalledApp] = [:]
        for app in apps.sorted(by: { $0.path < $1.path }) {
            let topic = CommunityTopic.hash(app)
            if let existing = topics[topic], !VersionOrder.isNewer(version: app.version, build: app.build, than: existing) { continue }
            topics[topic] = app
        }
        return topics.values.sorted {
            [$0.bundleID, $0.channel, $0.teamID ?? "", $0.path].lexicographicallyPrecedes([$1.bundleID, $1.channel, $1.teamID ?? "", $1.path])
        }
    }

    public static func batch(_ scope: [InstalledApp], offset: Int) -> P2PSyncBatch {
        guard !scope.isEmpty else { return .init(apps: [], start: 0, total: 0, nextOffset: 0) }
        let start = max(0, offset) % scope.count, end = min(start + batchSize, scope.count)
        return .init(apps: Array(scope[start..<end]), start: start, total: scope.count, nextOffset: end == scope.count ? 0 : end)
    }
}
