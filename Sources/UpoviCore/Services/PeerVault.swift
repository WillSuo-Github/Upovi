import Foundation
import Security

public enum PeerVault {
    public static func load() throws -> [PeerInvitation] {
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw PeerError.unavailable("Cannot read peer Keychain: \(status)") }
        let peers = try JSONDecoder().decode([PeerInvitation].self, from: data)
        for peer in peers { _ = try PeerInvitation(url: peer.url, name: peer.name) }
        return peers
    }

    public static func save(_ peers: [PeerInvitation]) throws {
        let data = try JSONEncoder().encode(peers)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base; query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw PeerError.unavailable("Cannot save peer Keychain: \(added)") }
        } else if status != errSecSuccess { throw PeerError.unavailable("Cannot update peer Keychain: \(status)") }
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.upovi.identity", kSecAttrAccount as String: "peers-v1"]
    }
}
