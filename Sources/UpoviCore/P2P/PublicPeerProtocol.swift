import Foundation
import CryptoKit

public enum CommunityTopic {
    public static func hash(_ app: InstalledApp) -> Data {
        hash(bundleID: app.bundleID, channel: app.channel, teamID: app.teamID)
    }

    public static func hash(_ report: VersionReport) -> Data {
        hash(bundleID: report.bundleID, channel: report.channel, teamID: report.teamID)
    }

    private static func hash(bundleID: String, channel: String, teamID: String?) -> Data {
        // This namespace is intentionally disjoint from torrent content hashes and v1 private salts.
        let parts: [BValue] = [.string("app.upovi.public-version.v2"), .string(bundleID), .string(channel), teamID.map(BValue.string) ?? .int(0)]
        return Data(Insecure.SHA1.hash(data: BValue.list(parts).encoded()))
    }

    public static func decode(_ record: MutableRecord, for app: InstalledApp, now: Date = Date()) throws -> VersionReport {
        guard record.salt == hash(app), record.isValid,
              record.sequence <= Int64(now.addingTimeInterval(300).timeIntervalSince1970 * 1000),
              let data = record.value.data else { throw PeerError.invalid("Invalid community report signature, sequence, or topic") }
        let report = try JSONDecoder().decode(VersionReport.self, from: data)
        try report.validate(now: now)
        guard report.bundleID == app.bundleID, report.channel == app.channel, report.teamID == app.teamID else {
            throw PeerError.invalid("Community application identity mismatch")
        }
        return report
    }
}

struct PublicPeerResponder: Sendable {
    let nodeID: Data
    let records: [Data: MutableRecord]
    private let cookieKey = SymmetricKey(size: .bits256)

    func respond(method: String, args: [String: BValue], endpoint: DHTEndpoint, now: Date = Date()) -> [String: BValue]? {
        guard let callerID = args["id"]?.data, callerID.count == 20, let topic = args["topic"]?.data,
              topic.count == 20, let record = records[topic] else { return nil }
        let minute = Int64(now.timeIntervalSince1970 / 60)
        if method == "upovi_hello" {
            return ["id": .bytes(nodeID), "token": .bytes(cookie(endpoint: endpoint, topic: topic, minute: minute))]
        }
        guard method == "upovi_report", let token = args["token"]?.data, token.count == 16,
              [minute, minute - 1].contains(where: { cookie(endpoint: endpoint, topic: topic, minute: $0) == token }),
              let payload = record.value.data, let report = try? JSONDecoder().decode(VersionReport.self, from: payload),
              (try? report.validate(now: now)) != nil else { return nil }
        return ["id": .bytes(nodeID), "k": .bytes(record.publicKey), "seq": .int(record.sequence),
                "sig": .bytes(record.signature), "v": record.value]
    }

    private func cookie(endpoint: DHTEndpoint, topic: Data, minute: Int64) -> Data {
        let input = BValue.list([.string(endpoint.host), .int(Int64(endpoint.port)), .bytes(topic), .int(minute)]).encoded()
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: cookieKey).prefix(16))
    }
}
