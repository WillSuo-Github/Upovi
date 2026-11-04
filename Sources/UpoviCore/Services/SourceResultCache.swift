import Foundation

/// Last-known version evidence is kept separately from the outcome of the current check.
/// It cannot authorize downloads, installations or fresh-update notifications.
public struct SourceResultCache: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        let app: InstalledApp
        let sourceOverride: SourceOverride?
        let result: SourceResult
    }
    private var entries: [String: Entry] = [:]
    public init() { }
    public init(data: Data?) {
        guard let data, data.count <= 8_000_000, let value = try? JSONDecoder().decode(Self.self, from: data), value.entries.count <= 1000 else { return }
        entries = value.entries
    }
    public func encoded() -> Data? {
        guard let data = try? JSONEncoder().encode(self), data.count <= 8_000_000 else { return nil }
        return data
    }
    public mutating func record(_ result: SourceResult, app: InstalledApp, sourceOverride: SourceOverride?, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.result.checkedAt) >= 0 && now.timeIntervalSince($0.value.result.checkedAt) <= 86400 }
        guard result.appID == app.id, result.retainedFrom == nil,
              result.status == .current || result.status == .updates || (result.status == .partial && !result.candidates.isEmpty),
              result.candidates.allSatisfy({ !$0.isCommunity && $0.requiresRevalidation != true }) else { return }
        let candidates = result.candidates.prefix(20).map { candidate in
            var candidate = candidate; candidate.releaseNotes = nil
            return candidate
        }
        let stored = SourceResult(appID: result.appID, candidates: candidates, note: String(result.note.prefix(2000)), status: result.status,
            manualURL: result.manualURL, checks: result.checks, appStoreID: result.appStoreID, installedVersion: result.installedVersion, checkedAt: result.checkedAt)
        entries[app.id] = .init(app: app, sourceOverride: sourceOverride, result: stored)
        if entries.count > 1000, let oldest = entries.min(by: { $0.value.result.checkedAt < $1.value.result.checkedAt })?.key { entries[oldest] = nil }
    }
    public func resolving(_ current: SourceResult, app: InstalledApp, sourceOverride: SourceOverride?, now: Date = Date()) -> SourceResult {
        guard current.appID == app.id, [.failed, .partial].contains(current.status),
              let old = entries[app.id], old.app == app, old.sourceOverride == sourceOverride,
              now >= old.result.checkedAt, now.timeIntervalSince(old.result.checkedAt) <= 86400 else { return current }
        let failed = Set(current.checks.filter { [.failed, .cancelled].contains($0.outcome) }.map(\.source))
        let retained = old.result.candidates.filter { candidate in
            guard let source = Self.source(candidate), failed.contains(source),
                  !current.candidates.contains(where: { Self.source($0) == Self.source(candidate) && VersionOrder.compare($0.version, candidate.version).map { $0 != .orderedAscending } == true }) else { return false }
            return true
        }.map { candidate in
            var candidate = candidate
            candidate.requiresRevalidation = true; candidate.download = nil
            candidate.releaseNotes = String(localized: "这是上次成功检查确认的版本；本次来源检查失败，不能据此下载安装。请等待来源恢复后重新检查。")
            return candidate
        }
        guard !retained.isEmpty else { return current }
        return .init(appID: app.id, candidates: current.candidates + retained,
            note: current.note + " · " + String(localized: "已保留 \(old.result.checkedAt.formatted(date: .abbreviated, time: .shortened)) 确认的更新，当前结果待重新核对。"), status: .partial,
            manualURL: current.manualURL ?? old.result.manualURL, checks: current.checks, appStoreID: current.appStoreID,
            installedVersion: current.installedVersion ?? old.result.installedVersion, checkedAt: current.checkedAt, retainedFrom: old.result.checkedAt)
    }
    private static func source(_ candidate: UpdateCandidate) -> SourceCheckDetail.Source? {
        if candidate.source.hasPrefix("Electron") { return .electron }
        if candidate.source.hasPrefix("GitHub") { return .github }
        if candidate.source == "Developer appcast" { return .appcast }
        if candidate.source == "Homebrew" { return .homebrew }
        if candidate.source == "Steam" { return .steam }
        return nil
    }
}
