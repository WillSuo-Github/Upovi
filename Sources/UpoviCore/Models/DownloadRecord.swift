import Foundation

public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        case queued, downloading, paused, waitingForNetwork, retrying, verifying, verified, failed, cancelled, interrupted
        public var active: Bool { [.queued, .downloading, .paused, .waitingForNetwork, .retrying, .verifying].contains(self) }
        public var canPause: Bool { [.queued, .downloading, .waitingForNetwork, .retrying].contains(self) }
    }
    public let id: UUID
    public let applicationID: String
    public let applicationName: String
    public let bundleID: String
    public let teamID: String?
    public let targetVersion: String
    public let createdAt: Date
    public var updatedAt: Date
    public var state: State
    public var received: Int64 = 0
    public var expected: Int64 = -1
    public var resumedBytes: Int64 = 0
    public var retries: Int = 0
    public var issue: DiagnosticIssue?
    public init(app: InstalledApp, targetVersion: String) {
        id = UUID(); applicationID = app.id; applicationName = app.name; bundleID = app.bundleID; teamID = app.teamID
        self.targetVersion = targetVersion; createdAt = Date(); updatedAt = createdAt; state = .queued
    }
}
