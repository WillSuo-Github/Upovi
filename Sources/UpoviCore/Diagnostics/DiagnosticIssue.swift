import Foundation

/// Export only fixed classifications and numeric codes, never an error's message or userInfo.
public struct DiagnosticIssue: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case cancelled, offline, timeout, tls, connection, http, invalidMetadata, validationRejected, operationFailed, unknown
    }
    public let kind: Kind
    public let code: Int?
    public let httpStatus: Int?
    public private(set) var rateLimited: Bool? = nil
    public private(set) var retryAt: Date? = nil
    public init(_ error: any Error) {
        if error is CancellationError { kind = .cancelled; code = nil; httpStatus = nil; return }
        if let http = error as? HTTPStatusError { kind = .http; code = nil; httpStatus = http.statusCode; rateLimited = http.rateLimited; retryAt = http.retryAt; return }
        httpStatus = nil
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            code = value.code
            switch value.code {
            case NSURLErrorCancelled: kind = .cancelled
            case NSURLErrorNotConnectedToInternet: kind = .offline
            case NSURLErrorTimedOut: kind = .timeout
            case -1206 ... -1200: kind = .tls
            default: kind = .connection
            }
        } else {
            code = nil
            if error is DecodingError { kind = .invalidMetadata }
            else if case PeerError.invalid = error { kind = .validationRejected }
            else if case PeerError.unavailable = error { kind = .operationFailed }
            else { kind = .unknown }
        }
    }
}

public struct SourceCheckDetail: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case appcast, homebrew, github, manual, appStore }
    public enum Outcome: String, Codable, Sendable { case checked, uncomparable, failed, cancelled, manual }
    public let source: Source
    public let outcome: Outcome
    public let issue: DiagnosticIssue?
    public init(_ source: Source, _ outcome: Outcome, error: (any Error)? = nil) {
        self.source = source; self.outcome = outcome; issue = error.map(DiagnosticIssue.init)
    }
}

public struct DiagnosticEvent: Codable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case preparation, installation, recovery, backupInspection, backupCleanup, batchPreparation, batchInstallation
    }
    public let date: Date
    public let applicationID: String?
    public let stage: Stage
    public let issue: DiagnosticIssue
    public init(applicationID: String?, stage: Stage, error: any Error, date: Date = Date()) {
        self.date = date; self.applicationID = applicationID; self.stage = stage; issue = .init(error)
    }
}
