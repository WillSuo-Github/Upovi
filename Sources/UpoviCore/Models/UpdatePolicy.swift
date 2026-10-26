import Foundation

public struct UpdatePolicy: Codable, Sendable {
    public var skipped: Set<String> = []
    public var deferredUntil: [String: Date] = [:]
    public init() { }
    public static func scope(_ app: InstalledApp) -> String { app.bundleID + "|" + app.channel + "|" + (app.teamID ?? "") }
    public static func key(_ candidate: UpdateCandidate, app: InstalledApp) -> String {
        scope(app) + "|" + canonicalVersion(candidate.version) + "|" + candidate.build + "|" + String(candidate.usesBuildVersion)
    }
    private static func canonicalVersion(_ value: String) -> String {
        var version = SourceVersion.normalize(value)
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        guard version.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil else { return value }
        var pieces = version.components(separatedBy: ".")
        while pieces.count > 1 && pieces.last == "0" { pieces.removeLast() }
        return pieces.joined(separator: ".")
    }
    public func allows(_ candidate: UpdateCandidate, app: InstalledApp, now: Date = Date()) -> Bool {
        !skipped.contains(Self.key(candidate, app: app)) && (deferredUntil[Self.scope(app)] ?? .distantPast) <= now
    }
    public func filtering(_ result: SourceResult, app: InstalledApp, now: Date = Date()) -> SourceResult {
        .init(appID: result.appID, candidates: result.candidates.filter { allows($0, app: app, now: now) },
              note: result.note, status: result.status, manualURL: result.manualURL)
    }
}
