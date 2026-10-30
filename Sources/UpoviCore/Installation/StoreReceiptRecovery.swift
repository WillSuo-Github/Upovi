import CryptoKit
import Foundation
import Security

public struct StoreReceiptRecovery: Codable, Hashable, Sendable {
    public let transactionID: UUID
    public let path: String
    public let sha256: String?
    public init(transactionID: UUID, path: String, sha256: String? = nil) {
        self.transactionID = transactionID; self.path = path; self.sha256 = sha256
    }
    public func validate() throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.utf8.count <= 4096, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.hasPrefix("/private/var/folders/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              sha256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else { throw PeerError.invalid("Invalid Store receipt recovery request") }
    }
}

public enum StoreReceiptVerifier {
    /// Recovery accepts only an Apple receipt-signing leaf anchored in Apple's system root certificates.
    public static func validate(_ data: Data, application: InstalledApp) throws {
        guard !data.isEmpty, data.count <= 1_000_000 else { throw PeerError.invalid("Invalid Store receipt size") }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
              data.withUnsafeBytes({ CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { throw PeerError.invalid("Invalid signed Store receipt") }
        var status = CMSSignerStatus.unsigned, trust: SecTrust?, signer: SecCertificate?
        guard CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trust, nil) == errSecSuccess,
              status == .valid, let trust,
              CMSDecoderCopySignerCert(decoder, 0, &signer) == errSecSuccess, let signer,
              SecCertificateCopySubjectSummary(signer) as String? == "Mac App Store and iTunes Store Receipt Signing" else {
            throw PeerError.invalid("The receipt is not signed by Apple's App Store receipt signer")
        }
        var keychain: SecKeychain?
        guard SecKeychainOpen("/System/Library/Keychains/SystemRootCertificates.keychain", &keychain) == errSecSuccess, let keychain else {
            throw PeerError.unavailable("Apple system root certificates are unavailable")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let certificates = value as? [SecCertificate] else {
            throw PeerError.unavailable("Apple system root certificates could not be read")
        }
        let anchors = certificates.filter { ["Apple Root CA", "Apple Root CA - G2", "Apple Root CA - G3"].contains(SecCertificateCopySubjectSummary($0) as String? ?? "") }
        guard !anchors.isEmpty, SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess, SecTrustEvaluateWithError(trust, nil) else {
            throw PeerError.invalid("The Store receipt certificate chain is not trusted")
        }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { throw PeerError.invalid("Missing Store receipt payload") }
        try validatePayload(content as Data, application: application)
    }

    static func validatePayload(_ data: Data, application: InstalledApp) throws {
        var root = DER(data)
        let set = try root.read(tag: 0x31)
        guard root.atEnd else { throw PeerError.invalid("Trailing Store receipt data") }
        var attributes = DER(set), identifiers: [String] = [], versions: [String] = []
        while !attributes.atEnd {
            var item = DER(try attributes.read(tag: 0x30))
            let typeBytes = try item.read(tag: 0x02)
            guard typeBytes.count <= 4 else { throw PeerError.invalid("Invalid Store receipt attribute") }
            let type = typeBytes.reduce(0) { $0 * 256 + Int($1) }
            _ = try item.read(tag: 0x02)
            let value = try item.read(tag: 0x04)
            guard item.atEnd else { throw PeerError.invalid("Invalid Store receipt attribute length") }
            if type == 2 || type == 3 {
                var string = DER(value)
                guard let text = String(data: try string.read(tag: 0x0C), encoding: .utf8), string.atEnd, text.count <= 255 else {
                    throw PeerError.invalid("Invalid Store receipt application identity")
                }
                if type == 2 { identifiers.append(text) } else { versions.append(text) }
            }
        }
        guard identifiers == [application.bundleID], versions.count == 1,
              VersionOrder.compare(versions[0], application.version) == .orderedSame else {
            throw PeerError.invalid("Store receipt belongs to a different application or version")
        }
    }

    private struct DER {
        let bytes: [UInt8]
        var position = 0
        init(_ data: Data) { bytes = Array(data) }
        var atEnd: Bool { position == bytes.count }
        mutating func read(tag: UInt8) throws -> Data {
            guard position + 2 <= bytes.count, bytes[position] == tag else { throw PeerError.invalid("Malformed Store receipt") }
            var length = Int(bytes[position + 1]); position += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, position + count <= bytes.count else { throw PeerError.invalid("Invalid Store receipt length") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[position]); position += 1 }
            }
            guard length <= bytes.count - position else { throw PeerError.invalid("Truncated Store receipt") }
            defer { position += length }
            return Data(bytes[position..<(position + length)])
        }
    }
}
