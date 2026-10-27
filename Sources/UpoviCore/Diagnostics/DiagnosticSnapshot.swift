import Foundation

/// Inputs stay in memory/private settings. Only the explicit report projection is exportable.
public struct DiagnosticSnapshot: Sendable, Identifiable {
    public let id = UUID()
    public let generatedAt: Date
    private let applications: [InstalledApp]
    private let results: [String: SourceResult]
    private let events: [DiagnosticEvent]
    private let transactions: [Transaction]
    private let environment: Environment
    private let online: Bool
    private let busy: Bool
    public struct Environment: Sendable {
        public let version: String
        public let build: String
        public let osMajor: Int
        public let osMinor: Int
        public let architecture: Architecture
        public enum Architecture: String, Codable, Sendable { case arm64, x86_64, unknown }
        public init(version: String, build: String, osMajor: Int, osMinor: Int, architecture: Architecture) {
            self.version = version; self.build = build; self.osMajor = osMajor; self.osMinor = osMinor; self.architecture = architecture
        }
    }
    public struct Transaction: Sendable {
        public enum Kind: String, Codable, Sendable { case application, administrator, batch, download }
        public enum State: String, Codable, Sendable {
            case pending, preparing, prepared, backedUp, installing, installed, restored, failed, cancelled, manual, interrupted
            case downloading, paused, waitingForNetwork, retrying, verifying, verified
            case backupDiscarded, awaitingAuthorization, interruptedOrFailed, cleanupPending, unknown
            public static func known(_ value: String) -> Self { Self(rawValue: value) ?? .unknown }
        }
        public let applicationID: String
        public let kind: Kind
        public let state: State
        public let date: Date
        public init(applicationID: String, kind: Kind, state: State, date: Date) {
            self.applicationID = applicationID; self.kind = kind; self.state = state; self.date = date
        }
    }
    public init(applications: [InstalledApp], results: [String: SourceResult], events: [DiagnosticEvent], transactions: [Transaction],
                environment: Environment, online: Bool, busy: Bool, generatedAt: Date = Date()) {
        self.applications = applications; self.results = results; self.events = events; self.transactions = transactions
        self.environment = environment; self.online = online; self.busy = busy; self.generatedAt = generatedAt
    }
    public func report(includingApplicationIdentifiers: Bool = false) throws -> Data {
        let apps = Array(applications.sorted { $0.id < $1.id }.prefix(1000))
        let references = Dictionary(apps.enumerated().map { ($0.element.id, String(format: "application-%03d", $0.offset + 1)) }, uniquingKeysWith: { a, _ in a })
        let summaries = apps.map { app -> ApplicationSummary in
            let result = results[app.id]
            let candidates = result?.candidates.filter { !$0.isCommunity } ?? []
            return .init(reference: references[app.id]!, bundleID: includingApplicationIdentifiers ? Self.identifier(app.bundleID) : nil,
                         version: includingApplicationIdentifiers ? Self.version(app.version) : nil,
                         build: includingApplicationIdentifiers ? Self.version(app.build) : nil,
                         channel: app.isAppStore ? .appStore : .developer, status: result?.status,
                         checks: Array((result?.checks ?? []).prefix(8)), sourceCandidateCount: candidates.count,
                         verifiableDownloadCount: candidates.filter { $0.download?.canVerify(for: app) == true }.count)
        }
        let counts = Dictionary(grouping: summaries, by: { $0.status?.rawValue ?? "notChecked" }).mapValues(\.count)
        let report = Report(schemaVersion: 1, generatedAt: generatedAt, includingApplicationIdentifiers: includingApplicationIdentifiers,
            environment: .init(version: Self.version(environment.version), build: Self.version(environment.build),
                               osMajor: max(0, environment.osMajor), osMinor: max(0, environment.osMinor), architecture: environment.architecture),
            online: online, operationInProgress: busy, totalApplications: applications.count,
            truncated: applications.count > apps.count || events.count > 50 || transactions.count > 200,
            sourceCounts: counts, applications: summaries,
            recentIssues: events.prefix(50).map { .init(date: $0.date, application: $0.applicationID.flatMap { references[$0] }, stage: $0.stage, issue: $0.issue) },
            transactions: transactions.prefix(200).map { .init(date: $0.date, application: references[$0.applicationID], kind: $0.kind, state: $0.state) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        guard data.count <= 2_000_000 else { throw PeerError.invalid("Diagnostic report exceeds its export limit") }
        return data
    }
    private static func identifier(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 256, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return value
    }
    private static func version(_ value: String) -> String? {
        guard value.count <= 128, !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ". _-+()".contains($0)) }) else { return nil }
        return value
    }
    private struct EnvironmentSummary: Encodable {
        let version: String?, build: String?
        let osMajor: Int, osMinor: Int
        let architecture: Environment.Architecture
    }
    private struct ApplicationSummary: Encodable {
        enum Channel: String, Encodable { case appStore, developer }
        let reference: String
        let bundleID: String?, version: String?, build: String?
        let channel: Channel
        let status: SourceStatus?
        let checks: [SourceCheckDetail]
        let sourceCandidateCount: Int, verifiableDownloadCount: Int
    }
    private struct EventSummary: Encodable {
        let date: Date
        let application: String?
        let stage: DiagnosticEvent.Stage
        let issue: DiagnosticIssue
    }
    private struct TransactionSummary: Encodable {
        let date: Date
        let application: String?
        let kind: Transaction.Kind
        let state: Transaction.State
    }
    private struct Report: Encodable {
        let schemaVersion: Int
        let generatedAt: Date
        let includingApplicationIdentifiers: Bool
        let environment: EnvironmentSummary
        let online: Bool, operationInProgress: Bool
        let totalApplications: Int
        let truncated: Bool
        let sourceCounts: [String: Int]
        let applications: [ApplicationSummary]
        let recentIssues: [EventSummary]
        let transactions: [TransactionSummary]
    }
}
