import Foundation

public enum CommunityConfirmation: Equatable, Sendable {
    case unverified, multiplePublishers, sourceMatched
}

public struct CommunityLead: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let version: String
        public let build: String
    }
    public var id: ID { .init(version: report.version, build: report.build) }
    public let report: UpdateCandidate
    public let publisherCount: Int
    public let confirmation: CommunityConfirmation
    public let matchingSources: [String]
}

public struct SourceUpdateNotice: Sendable {
    public let app: InstalledApp
    public let candidates: [UpdateCandidate]
    public var deduplicationKeys: Set<String> {
        Set(candidates.map { Self.key(app: app, candidate: $0) })
    }
    static func key(app: InstalledApp, candidate: UpdateCandidate) -> String {
        app.bundleID + ":" + candidate.version + ":" + candidate.build
    }
}

/// A peer observation never becomes an update authority, even when many keys repeat it.
public struct UpdateAssessment: Sendable {
    public let sourceUpdates: [UpdateCandidate]
    public let communityLeads: [CommunityLead]
    public var hasUpdate: Bool { !sourceUpdates.isEmpty }

    public init(app: InstalledApp, sourceResult: SourceResult?, reports: [UpdateCandidate] = [], now: Date = Date()) {
        let usableSource = sourceResult?.appID == app.id && (sourceResult?.status == .updates || sourceResult?.status == .partial)
        let sources = usableSource ? sourceResult?.candidates ?? [] : []
        sourceUpdates = sources.filter { candidate in
            guard !candidate.isCommunity else { return false }
            return candidate.usesBuildVersion
                ? !app.build.isEmpty && VersionOrder.compare(candidate.build, app.build) == .orderedDescending
                : VersionOrder.isNewer(version: candidate.version, build: candidate.build, than: app)
        }.sorted { VersionOrder.compare($0.version, $1.version) == .orderedDescending }
        let liveReports = reports.filter {
            $0.isCommunity && ($0.expiresAt ?? $0.observedAt.addingTimeInterval(86400)) > now &&
                $0.observedAt <= now.addingTimeInterval(300) &&
                VersionOrder.isNewer(version: $0.version, build: $0.build, than: app)
        }
        let grouped = Dictionary(grouping: liveReports) { CommunityLead.ID(version: $0.version, build: $0.build) }
        let checkedSources = sourceUpdates
        communityLeads = grouped.values.compactMap { reports in
            guard let latest = reports.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
            let publishers = Set(reports.compactMap(\.peerID).filter { !$0.isEmpty })
            // A matching version cannot attest an unspecified or different build.
            let matches = checkedSources.filter {
                !$0.usesBuildVersion && VersionOrder.compare($0.version, latest.version) == .orderedSame &&
                    (latest.build.isEmpty || (!($0.build.isEmpty) && $0.build == latest.build))
            }
            return CommunityLead(report: latest, publisherCount: publishers.count,
                confirmation: !matches.isEmpty ? .sourceMatched : publishers.count > 1 ? .multiplePublishers : .unverified,
                matchingSources: Array(Set(matches.map(\.source))).sorted())
        }.sorted {
            let order = VersionOrder.compare($0.report.version, $1.report.version)
            if order == .orderedSame { return $0.report.build < $1.report.build }
            return order == .orderedDescending
        }
    }

    /// Shared by notification scheduling and its regression tests; peer data cannot enter the batch or dedup state.
    public static func notificationBatch(apps: [InstalledApp], results: [String: SourceResult], ignored: Set<String>, seen: Set<String>) -> [SourceUpdateNotice] {
        apps.compactMap { app in
            guard !ignored.contains(app.bundleID) else { return nil }
            let eligible = UpdateAssessment(app: app, sourceResult: results[app.id]).sourceUpdates.filter {
                !seen.contains(SourceUpdateNotice.key(app: app, candidate: $0))
            }
            return eligible.isEmpty ? nil : SourceUpdateNotice(app: app, candidates: eligible)
        }
    }
}
