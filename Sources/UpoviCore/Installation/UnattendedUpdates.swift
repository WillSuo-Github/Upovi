import Foundation

/// Consent belongs to one concrete installed identity and release channel, never a display name.
public struct UnattendedGrant: Codable, Sendable, Equatable, Identifiable {
    public var id: String { application.path }
    public let application: InstalledApp
    public let channel: ReleaseChannel
    public init(application: InstalledApp, channel: ReleaseChannel) throws {
        guard !application.isAppStore, application.bundleID != "app.upovi.Upovi",
              let team = application.teamID, team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              ApplicationSourceCatalog.replacementTeam(for: application) == team,
              ApplicationSourceCatalog.legacyMigration(for: application) == nil,
              ApplicationSourceCatalog.developerTeamMigration(for: application) == nil else {
            throw PeerError.invalid("Unattended updates require a direct-distribution application with an unchanged developer identity")
        }
        self.application = application; self.channel = channel
    }
    public func matches(_ app: InstalledApp, channel: ReleaseChannel) -> Bool {
        app.path == application.path && app.bundleID == application.bundleID && app.teamID == application.teamID &&
            !app.isAppStore && self.channel == channel
    }
}

public struct UnattendedUpdateRecord: Codable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable { case preparing, installing, installed, current, deferred, failed, cancelled, interrupted }
    public let id: UUID
    public let application: InstalledApp
    public let version: String
    public let build: String
    public let channel: ReleaseChannel
    public let startedAt: Date
    public var finishedAt: Date?
    public var phase: Phase
    public var detail: String
    public init(app: InstalledApp, candidate: UpdateCandidate, channel: ReleaseChannel, now: Date = Date()) {
        id = UUID(); application = app; version = candidate.version; build = candidate.build
        self.channel = channel; startedAt = now; phase = .preparing; detail = ""
    }
}

public struct UnattendedUpdateState: Codable, Sendable {
    public var enabled = false
    public var grants: [UnattendedGrant] = []
    public var attempts: [String: UnattendedUpdateRecord] = [:]
    public var history: [UnattendedUpdateRecord] = []
    public init() {}
    public func grant(for app: InstalledApp, channel: ReleaseChannel) -> UnattendedGrant? {
        grants.first { $0.matches(app, channel: channel) }
    }
    public mutating func recoverInterrupted() {
        for i in history.indices where history[i].finishedAt == nil {
            history[i].phase = .interrupted
            history[i].detail = String(localized: "上次无人值守任务中断；不会自动恢复该次安装。")
            history[i].finishedAt = Date()
        }
    }
    public mutating func record(_ value: UnattendedUpdateRecord) {
        if let i = history.firstIndex(where: { $0.id == value.id }) { history[i] = value }
        else { history.insert(value, at: 0) }
        history = Array(history.prefix(100))
        if grants.contains(where: { $0.id == value.application.id }) { attempts[value.application.id] = value }
        else { attempts[value.application.id] = nil }
    }
}

public enum UnattendedUpdatePolicy {
    public enum Deferral: String, Sendable { case disabled, notGranted, ignored, channel, incompleteSource, policy, running, authorization, unverified, cooldown }
    public static func deferral(app: InstalledApp, candidate: UpdateCandidate, result: SourceResult?,
                                state: UnattendedUpdateState, channel: ReleaseChannel, ignored: Set<String>,
                                updatePolicy: UpdatePolicy, running: Bool, writable: Bool, now: Date = Date(), currentAttempt: UUID? = nil) -> Deferral? {
        guard state.enabled else { return .disabled }
        guard state.grant(for: app, channel: channel) != nil else { return .notGranted }
        guard (try? UnattendedGrant(application: app, channel: channel)) != nil else { return .notGranted }
        guard !ignored.contains(app.bundleID) else { return .ignored }
        guard channel.permits(candidate) else { return .channel }
        guard result?.appID == app.id, result?.status == .updates,
              result?.candidates.contains(candidate) == true else { return .incompleteSource }
        guard updatePolicy.allows(candidate, app: app, now: now), candidate.isNewer(than: app) else { return .policy }
        guard !running else { return .running }
        guard writable, !app.isAppStore, app.bundleID != "app.upovi.Upovi" else { return .authorization }
        guard !candidate.isCommunity, let download = candidate.download, download.hasIntegrityProof,
              download.url.scheme == "https", download.url.host != nil, download.url.user == nil, download.url.password == nil,
              ["zip", "dmg"].contains(download.declaredFormat ?? ""),
              ApplicationSourceCatalog.replacementTeam(for: app) == app.teamID,
              ApplicationSourceCatalog.developerTeamMigration(for: app) == nil,
              ApplicationSourceCatalog.legacyMigration(for: app) == nil else { return .unverified }
        guard let result, let planned = BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first,
              planned.canInstall, planned.candidate == candidate else { return .unverified }
        if let last = state.attempts[app.id], last.phase != .deferred, last.id != currentAttempt, last.version == candidate.version, last.build == candidate.build,
           last.channel == channel, now.timeIntervalSince(last.startedAt) < 86400 { return .cooldown }
        return nil
    }
}
