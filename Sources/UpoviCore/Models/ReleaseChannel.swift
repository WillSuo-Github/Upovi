import Foundation

public enum ReleaseChannel: String, Codable, Sendable, CaseIterable {
    case stable, beta
    public func permits(_ candidate: UpdateCandidate) -> Bool { self == .beta || !candidate.isPrerelease }
}
