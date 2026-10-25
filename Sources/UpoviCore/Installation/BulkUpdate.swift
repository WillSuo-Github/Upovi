import Foundation

public struct BulkUpdateItem: Identifiable, Sendable {
    public var id: String { application.id }
    public let application: InstalledApp
    public let candidate: UpdateCandidate
    public let manualReason: String?
    public var canInstall: Bool { manualReason == nil }
}

public enum BulkUpdatePlan {
    /// Uses the complete inventory and source authority, independently of the visible table filters.
    public static func make(apps: [InstalledApp], results: [String: SourceResult], ignored: Set<String>) -> [BulkUpdateItem] {
        var paths = Set<String>()
        return apps.sorted { $0.path < $1.path }.compactMap { app in
            guard paths.insert(app.id).inserted, !ignored.contains(app.bundleID) else { return nil }
            let candidates = UpdateAssessment(app: app, sourceResult: results[app.id]).sourceUpdates.sorted {
                let order = VersionOrder.compare($0.version, $1.version)
                return order == .orderedSame ? VersionOrder.compare($0.build, $1.build) == .orderedDescending : order == .orderedDescending
            }
            guard let latest = candidates.first else { return nil }
            // Prefer a downloadable source for the same target; never silently fall back to an older release.
            let sameTarget = candidates.filter { $0.version == latest.version && $0.build == latest.build }
            let candidate = sameTarget.first { manualReason(app: app, candidate: $0) == nil } ?? latest
            return BulkUpdateItem(application: app, candidate: candidate, manualReason: manualReason(app: app, candidate: candidate))
        }
    }

    private static func manualReason(app: InstalledApp, candidate: UpdateCandidate) -> String? {
        if app.isAppStore { return "请通过 App Store 更新" }
        if app.bundleID == "app.upovi.Upovi" { return "请使用 Upovi 自身更新" }
        guard let team = app.teamID, !team.isEmpty else { return "无法确认已安装应用的开发者，请使用官方更新" }
        guard let download = candidate.download, download.hasIntegrityProof else { return "来源未提供可验证的下载，请使用官方更新" }
        guard ["zip", "dmg", "pkg"].contains(download.url.pathExtension.lowercased()) else { return "此安装格式需使用官方更新" }
        return nil
    }
}

public struct BulkUpdateOutcome: Sendable {
    public enum Status: Sendable { case installed, failed, cancelled, manual }
    public let item: BulkUpdateItem
    public let status: Status
    public let detail: String
}

public enum BulkUpdateEvent: Sendable {
    case started(BulkUpdateItem)
    case finished(BulkUpdateOutcome)
}

public enum BulkUpdateRunner {
    /// A failed application does not suppress later updates. Stop is checked between atomic operations.
    public static func run(_ items: [BulkUpdateItem],
                           shouldStop: @Sendable () async -> Bool,
                           operation: @Sendable (BulkUpdateItem) async throws -> Void,
                           report: @Sendable (BulkUpdateEvent) async -> Void) async -> [BulkUpdateOutcome] {
        var outcomes: [BulkUpdateOutcome] = []
        for item in items {
            let outcome: BulkUpdateOutcome
            let stopped = await shouldStop()
            if !item.canInstall {
                outcome = .init(item: item, status: .manual, detail: item.manualReason ?? "请使用官方更新")
            } else if Task.isCancelled || stopped {
                outcome = .init(item: item, status: .cancelled, detail: "已停止，未安装")
            } else {
                await report(.started(item))
                do {
                    try await operation(item)
                    // Once an installation commits, report success even if stop was requested meanwhile.
                    outcome = .init(item: item, status: .installed, detail: "更新完成，主应用备份已保留")
                } catch {
                    outcome = .init(item: item, status: Task.isCancelled || error is CancellationError ? .cancelled : .failed,
                                    detail: Task.isCancelled || error is CancellationError ? "已取消，未完成安装" : error.localizedDescription)
                }
            }
            outcomes.append(outcome)
            await report(.finished(outcome))
        }
        return outcomes
    }
}
