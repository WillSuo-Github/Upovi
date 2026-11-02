import Foundation

public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        case queued, downloading, paused, waitingForNetwork, retrying, verifying, downloaded, verified, failed, cancelled, interrupted
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
    public var recoveryStatus: String? {
        switch state {
        case .retrying: String(localized: "网络请求未完成，正在自动重试（\(retries)/3）…")
        case .waitingForNetwork: String(localized: "等待网络恢复，连接后自动继续…")
        case .paused: String(localized: "下载已暂停，可在“下载”中继续")
        case .downloading where retries > 0 && received == 0: String(localized: "正在重新连接并接续下载（已重试 \(retries)/3）…")
        default: nil
        }
    }
    public init(app: InstalledApp, targetVersion: String) {
        id = UUID(); applicationID = app.id; applicationName = app.name; bundleID = app.bundleID; teamID = app.teamID
        self.targetVersion = targetVersion; createdAt = Date(); updatedAt = createdAt; state = .queued
    }
}

/// A terminal download timeout keeps the transport classification and the actual retry count.
public struct DownloadTimeoutError: LocalizedError, Sendable {
    public let retries: Int
    public let received: Int64
    public init(retries: Int, received: Int64) { self.retries = retries; self.received = received }
    public var errorDescription: String? {
        String(localized: "安装包下载超时，自动重试 \(retries) 次后仍未完成。请检查网络后重试未完成项；本次尚未安装更新。")
    }
}
