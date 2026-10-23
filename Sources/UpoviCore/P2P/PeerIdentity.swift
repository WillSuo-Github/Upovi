import Foundation
import CryptoKit
import Security

public struct PeerInvitation: Codable, Identifiable, Hashable, Sendable {
    public var id: String { publicKey.base64EncodedString() }
    public var name: String
    public let publicKey: Data
    public let readKey: Data
    public var shortID: String { Data(SHA256.hash(data: publicKey)).prefix(6).map { String(format: "%02x", $0) }.joined() }

    public var url: String {
        var components = URLComponents()
        components.scheme = "upovi"; components.host = "peer"
        components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "key", value: publicKey.base64EncodedString()),
                                 URLQueryItem(name: "read", value: readKey.base64EncodedString())]
        return components.string!
    }

    public init(name: String, publicKey: Data, readKey: Data) {
        self.name = name; self.publicKey = publicKey; self.readKey = readKey
    }

    public init(url text: String, name: String = "Peer") throws {
        guard text.count < 1024, let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "upovi", components.host == "peer" else { throw PeerError.invalid("Invalid Upovi invitation") }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "v" }).count == 1, items.first(where: { $0.name == "v" })?.value == "1",
              items.filter({ $0.name == "key" }).count == 1, items.filter({ $0.name == "read" }).count == 1,
              let pubText = items.first(where: { $0.name == "key" })?.value, let pub = Data(base64Encoded: pubText), pub.count == 32,
              let readText = items.first(where: { $0.name == "read" })?.value, let read = Data(base64Encoded: readText), read.count == 32 else {
            throw PeerError.invalid("Invalid invitation keys")
        }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        self.init(name: name, publicKey: pub, readKey: read)
    }

    public func salt(bundleID: String, channel: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("upovi/v1/\(channel)/\(bundleID)".utf8), using: SymmetricKey(data: readKey)))
    }
}

public struct PeerIdentity: Codable, Sendable {
    private let signingKey: Data
    private let readKey: Data

    public init() {
        signingKey = Curve25519.Signing.PrivateKey().rawRepresentation
        readKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private enum CodingKeys: String, CodingKey { case signingKey, readKey }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signingKey = try container.decode(Data.self, forKey: .signingKey)
        readKey = try container.decode(Data.self, forKey: .readKey)
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        guard readKey.count == 32 else { throw PeerError.invalid("Invalid identity read key") }
    }

    public var invitation: PeerInvitation {
        .init(name: "My Upovi", publicKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: signingKey).publicKey.rawRepresentation, readKey: readKey)
    }

    public func seal(_ report: VersionReport, sequence: Int64) throws -> MutableRecord {
        try report.validate(now: Date())
        let peer = invitation
        let salt = peer.salt(bundleID: report.bundleID, channel: report.channel)
        let aad = Data("upovi-record-v1".utf8) + peer.publicKey + salt
        let plain = try JSONEncoder().encode(report)
        guard let encrypted = try AES.GCM.seal(plain, using: SymmetricKey(data: readKey), authenticating: aad).combined else {
            throw PeerError.invalid("Encryption failed")
        }
        var record = MutableRecord(publicKey: peer.publicKey, salt: salt, sequence: sequence, value: .bytes(encrypted), signature: Data())
        guard record.value.encoded().count <= 1000 else { throw PeerError.invalid("Version record exceeds BEP 44 limit") }
        record.signature = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey).signature(for: record.signable)
        return record
    }

    public func signPublic(_ report: VersionReport, sequence: Int64) throws -> MutableRecord {
        try report.validate(now: Date())
        let value = BValue.bytes(try JSONEncoder().encode(report))
        var record = MutableRecord(publicKey: invitation.publicKey, salt: CommunityTopic.hash(report), sequence: sequence, value: value, signature: Data())
        guard value.encoded().count <= 1000 else { throw PeerError.invalid("Public report exceeds BEP 44 limit") }
        record.signature = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey).signature(for: record.signable)
        return record
    }

    public static func loadOrCreate(account: String = "dht-v1") throws -> PeerIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.upovi.identity",
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let identity = try JSONDecoder().decode(PeerIdentity.self, from: data)
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.signingKey)
            guard identity.readKey.count == 32 else { throw PeerError.invalid("Invalid saved identity") }
            return identity
        }
        guard status == errSecItemNotFound else { throw PeerError.unavailable("Keychain error: \(status)") }
        let identity = PeerIdentity()
        var insert = query; insert.removeValue(forKey: kSecReturnData as String)
        insert[kSecValueData as String] = try JSONEncoder().encode(identity)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw PeerError.unavailable("Cannot save identity: \(added)") }
        return identity
    }
}

public struct VersionReport: Codable, Sendable, Equatable {
    public let bundleID: String
    public let version: String
    public let build: String
    public let channel: String
    public let teamID: String?
    public let observedAt: Date
    public let expiresAt: Date

    public init(app: InstalledApp, now: Date = Date()) {
        bundleID = app.bundleID; version = app.version; build = app.build; channel = app.channel; teamID = app.teamID
        observedAt = now; expiresAt = now.addingTimeInterval(24 * 3600)
    }

    public func validate(now: Date) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255, !version.isEmpty, version.utf8.count <= 128,
              build.utf8.count <= 128, (teamID?.count ?? 0) <= 64,
              ["developer", "app-store"].contains(channel), observedAt <= now.addingTimeInterval(300),
              expiresAt > now, expiresAt > observedAt, expiresAt.timeIntervalSince(observedAt) <= 24 * 3600 + 1 else {
            throw PeerError.invalid("Invalid or expired version record")
        }
    }

    public static func open(_ record: MutableRecord, from peer: PeerInvitation, bundleID: String, channel: String, now: Date = Date()) throws -> VersionReport {
        let salt = peer.salt(bundleID: bundleID, channel: channel)
        guard record.publicKey == peer.publicKey, record.salt == salt, record.isValid,
              let encrypted = record.value.data else { throw PeerError.invalid("Record signature or identity mismatch") }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: peer.readKey),
                                     authenticating: Data("upovi-record-v1".utf8) + peer.publicKey + salt)
        let report = try JSONDecoder().decode(VersionReport.self, from: plain)
        try report.validate(now: now)
        guard report.bundleID == bundleID, report.channel == channel else { throw PeerError.invalid("Application identity mismatch") }
        return report
    }
}

public struct MutableRecord: Sendable {
    public let publicKey: Data
    public let salt: Data
    public let sequence: Int64
    public let value: BValue
    public var signature: Data

    public var target: Data { Data(Insecure.SHA1.hash(data: publicKey + salt)) }
    public var signable: Data {
        var result = Data()
        if !salt.isEmpty { result += BValue.string("salt").encoded() + BValue.bytes(salt).encoded() }
        return result + BValue.string("seq").encoded() + BValue.int(sequence).encoded() + BValue.string("v").encoded() + value.encoded()
    }
    public var isValid: Bool {
        guard publicKey.count == 32, signature.count == 64, salt.count <= 64, sequence >= 0, value.encoded().count <= 1000,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: signable)
    }
}
