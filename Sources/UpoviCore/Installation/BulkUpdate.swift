import Foundation

public struct BulkUpdateItem: Identifiable, Codable, Sendable {
    public var id: String { application.id }
    public let application: InstalledApp
    public let candidate: UpdateCandidate
    public let manualReason: String?
    public var canInstall: Bool { manualReason == nil }
    public init(application: InstalledApp, candidate: UpdateCandidate, manualReason: String?) {
        self.application = application; self.candidate = candidate; self.manualReason = manualReason
    }
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
            let sameTarget = candidates.filter { VersionOrder.compare($0.version, latest.version) == .orderedSame && $0.build == latest.build && $0.usesBuildVersion == latest.usesBuildVersion }
            let candidate = sameTarget.first { manualReason(app: app, candidate: $0) == nil } ?? latest
            return BulkUpdateItem(application: app, candidate: candidate, manualReason: manualReason(app: app, candidate: candidate))
        }
    }

    private static func manualReason(app: InstalledApp, candidate: UpdateCandidate) -> String? {
        if app.isAppStore {
            guard let id = candidate.appStoreID else { return String(localized: "商店更新尚未取得可核对的应用标识") }
            do { try AppStoreUpdatePlan(application: app, storeID: id, version: candidate.version, userID: 501).validate(); return nil }
            catch { return String(localized: "此商店应用的位置或身份不支持由 Upovi 发起更新") }
        }
        if app.bundleID == "app.upovi.Upovi" { return String(localized: "请使用 Upovi 自身更新") }
        guard ApplicationSourceCatalog.replacementTeam(for: app) != nil else { return String(localized: "无法确认已安装应用的开发者，请使用官方更新") }
        guard let download = candidate.download, download.canVerify(for: app) else { return String(localized: "来源未提供可验证的下载，请使用官方更新") }
        guard ["zip", "dmg", "pkg"].contains(download.url.pathExtension.lowercased()) else { return String(localized: "此安装格式需使用官方更新") }
        return nil
    }
}

public struct BulkUpdateOutcome: Sendable {
    public enum Status: String, Codable, Sendable { case installed, current, failed, cancelled, manual }
    public let item: BulkUpdateItem
    public let status: Status
    public let detail: String
}

public enum BulkUpdateEvent: Sendable {
    case started(BulkUpdateItem)
    case finished(BulkUpdateOutcome)
}

public enum BulkUpdateRunner {
    public static let defaultConcurrency = 5
    public static let concurrencyRange = 1...8

    /// A failed application does not suppress later updates. Stop is checked before each application starts.
    /// Up to `concurrency` operations run at once; outcomes keep the input order.
    public static func run(_ items: [BulkUpdateItem],
                           concurrency: Int = 1,
                           shouldStop: @Sendable () async -> Bool,
                           operation: @escaping @Sendable (BulkUpdateItem) async throws -> Void,
                           report: @escaping @Sendable (BulkUpdateEvent) async -> Void) async -> [BulkUpdateOutcome] {
        let width = min(max(1, concurrency), concurrencyRange.upperBound)
        var outcomes = [BulkUpdateOutcome?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, BulkUpdateOutcome).self) { group in
            var running = 0
            for (index, item) in items.enumerated() {
                if !item.canInstall {
                    let outcome = BulkUpdateOutcome(item: item, status: .manual, detail: item.manualReason ?? String(localized: "请使用官方更新"))
                    outcomes[index] = outcome; await report(.finished(outcome)); continue
                }
                // Wait for a free slot before deciding whether this item may still start.
                while running >= width, let (finished, outcome) = await group.next() {
                    running -= 1; outcomes[finished] = outcome
                }
                let stopped = await shouldStop()
                if Task.isCancelled || stopped {
                    let outcome = BulkUpdateOutcome(item: item, status: .cancelled, detail: String(localized: "已停止，未安装"))
                    outcomes[index] = outcome; await report(.finished(outcome)); continue
                }
                await report(.started(item))
                running += 1
                group.addTask {
                    let outcome = await execute(item, operation: operation)
                    await report(.finished(outcome))
                    return (index, outcome)
                }
            }
            for await (finished, outcome) in group { outcomes[finished] = outcome }
        }
        return outcomes.compactMap { $0 }
    }

    private static func execute(_ item: BulkUpdateItem, operation: @Sendable (BulkUpdateItem) async throws -> Void) async -> BulkUpdateOutcome {
        do {
            try await operation(item)
            // Once an installation commits, report success even if stop was requested meanwhile.
            return .init(item: item, status: .installed, detail: item.application.isAppStore ? String(localized: "商店更新完成，不提供 Upovi 旧版备份") : String(localized: "更新完成，主应用备份已保留"))
        } catch is AppStoreAlreadyCurrent {
            return .init(item: item, status: .current, detail: String(localized: "商店确认已经最新，未执行升级"))
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            return .init(item: item, status: cancelled ? .cancelled : .failed, detail: cancelled ? String(localized: "已取消，未完成安装") : error.localizedDescription)
        }
    }
}

/// FIFO mutual exclusion for steps that must not overlap, such as system authorization prompts.
public actor SerialGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        return try await body()
    }
    private func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
