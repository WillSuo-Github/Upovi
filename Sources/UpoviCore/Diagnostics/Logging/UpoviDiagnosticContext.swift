import CryptoKit
import Foundation

/// Correlation fields shared by the app, sources, transports and installer.
public enum UpoviDiagnosticContext {
    @TaskLocal public static var operationID: String?

    /// Detached verification must retain the caller's operation parent.
    public static func detached<T: Sendable>(priority: TaskPriority? = nil, operation: @escaping @Sendable () async throws -> T) -> Task<T, any Error> {
        let parent = operationID
        return Task.detached(priority: priority) { try await $operationID.withValue(parent) { try await operation() } }
    }
    /// Only fixed helper markers cross the export boundary; raw authorization logs do not.
    public static func helperFailureSummary(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(65536), as: UTF8.self)
        let pattern = #"(?m)^UPOVI_INSTALLER_DIAGNOSTIC stage=([A-Za-z0-9._-]{1,64}) domain=(NSCocoaErrorDomain|NSPOSIXErrorDomain|NSOSStatusErrorDomain|NSURLErrorDomain|other) code=(-?[0-9]{1,12})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let stage = Range(match.range(at: 1), in: text), let domain = Range(match.range(at: 2), in: text), let code = Range(match.range(at: 3), in: text) else { return nil }
        return "helperStage=\(text[stage]) helperDomain=\(text[domain]) helperCode=\(text[code])"
    }
    public static func applicationID(_ identity: String) -> String { fingerprint(identity) }
    public static func application(_ app: InstalledApp) -> String {
        "app=\(applicationID(app.id)) installedVersion=\(app.version) installedBuild=\(app.build) channel=\(app.channel)"
    }
    public static func source(_ url: URL?) -> String {
        guard let url else { return "origin=none source=none" }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.user = nil; parts?.password = nil; parts?.query = nil; parts?.fragment = nil
        let family: String
        switch url.host?.lowercased() {
        case "api.github.com": family = "githubAPI"
        case "github.com", "raw.githubusercontent.com": family = "githubPublic"
        case "formulae.brew.sh": family = "homebrew"
        case "client-update.steamstatic.com": family = "steam"
        case "itunes.apple.com", "apps.apple.com": family = "appleStore"
        default: family = url.isFileURL ? "local" : "otherHTTPS"
        }
        return "origin=\(family) source=\(fingerprint(parts?.string ?? "invalid"))"
    }
    public static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public static func isCancellation(_ error: any Error) -> Bool {
        let value = error as NSError
        return error is CancellationError || (value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled)
    }
    public static func errorSummary(_ error: any Error) -> String {
        var value: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>(), chain: [String] = []
        while let current = value, chain.count < 4, seen.insert(ObjectIdentifier(current)).inserted {
            chain.append("domain=\(current.domain) code=\(current.code)")
            value = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let issue = DiagnosticIssue(error)
        var extra = "kind=\(issue.kind.rawValue)"
        if let status = issue.httpStatus { extra += " httpStatus=\(status) rateLimited=\(issue.rateLimited == true)" }
        if let date = issue.retryAt { extra += " retryAt=\(date.ISO8601Format())" }
        if let finalization = error as? AdministratorFinalizationError {
            extra += " finalizationDomain=\(finalization.domain) finalizationCode=\(finalization.code)"
        }
        // Bounded descriptions retain permission/validation reasons; userInfo and output bodies are never dumped.
        let detail: String
        if let store = error as? StoreInstallationError {
            extra += " storeStage=\(store.failure.stage) storeDomain=\(store.failure.domain) storeCode=\(store.failure.code) appManagementRequired=\(store.failure.requiresAppManagement)"
            detail = "Store installer output omitted; structured stage/domain/code retained"
        } else if error.localizedDescription.hasPrefix("Authorized installer failed:") {
            detail = "Privileged installer output omitted; see session result status"
        } else { detail = String(decoding: error.localizedDescription.utf8.prefix(1024), as: UTF8.self) }
        return UpoviLogPrivacy.sanitize("\(extra) \(chain.joined(separator: " <- ")) detail=\(detail)")
    }
    public static func sourceResult(_ result: SourceResult) -> String {
        let checks = result.checks.map { check in
            var value = "\(check.source.rawValue):\(check.outcome.rawValue)"
            if let issue = check.issue {
                value += ":\(issue.kind.rawValue):\(issue.httpStatus ?? issue.code ?? 0)"
                if let retryAt = issue.retryAt { value += ":retryAt=\(retryAt.ISO8601Format())" }
            }
            return value
        }.joined(separator: ",")
        let versions = result.candidates.prefix(8).map { "\($0.version):retained=\($0.requiresRevalidation == true):proof=\($0.download?.hasIntegrityProof == true)" }.joined(separator: ",")
        return "status=\(result.status.rawValue) checks=[\(checks)] candidates=[\(versions)] clientBuild=\(result.installedVersion ?? "none") retained=\(result.retainedFrom != nil)"
    }
}

/// Monotonic durations keep clock adjustments from distorting operation timing.
public struct UpoviLogOperation: Sendable {
    public let id: String
    private let name: String
    private let category: UpoviLogCategory
    private let manager: UpoviLogManager
    private let parent: String
    private let started = ContinuousClock.now
    public init(_ name: String, category: UpoviLogCategory, details: String = "", id: String = UUID().uuidString,
                manager: UpoviLogManager = .shared, file: String = #fileID, line: Int = #line) {
        self.name = name; self.category = category; self.manager = manager; self.id = id
        parent = UpoviDiagnosticContext.operationID ?? "none"
        event("started", details: details, file: file, line: line)
    }
    public func event(_ event: String, details: String = "", level: UpoviLogLevel = .info, file: String = #fileID, line: Int = #line) {
        manager.log("operation=\(name) request=\(id) parent=\(parent) event=\(event) elapsed=\(started.duration(to: .now)) \(details)",
                    level: level, category: category, file: file, line: line)
    }
    public func finish(_ outcome: String = "completed", details: String = "", level: UpoviLogLevel = .info, file: String = #fileID, line: Int = #line) {
        event(outcome, details: details, level: level, file: file, line: line)
    }
    public func fail(_ error: any Error, file: String = #fileID, line: Int = #line) {
        if error is ApplicationAlreadyCurrent || error is AppStoreAlreadyCurrent {
            finish("alreadyCurrent", file: file, line: line); return
        }
        finish(UpoviDiagnosticContext.isCancellation(error) ? "cancelled" : "failed", details: UpoviDiagnosticContext.errorSummary(error),
               level: UpoviDiagnosticContext.isCancellation(error) ? .info : .error, file: file, line: line)
    }
}
