import Foundation
import CoreFoundation

public enum GlobalP2PSettings {
    public static let key = "p2pEnabledV3"
    public static let legacyKeys = ["publicDiscoveryEnabledV2", "publicSharingEnabledV2", "selectedBundles"]

    public static func storedEnabled(in values: [String: Any]) -> Bool? {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    public static func migrated(_ values: [String: Any], existingInstallation: Bool) -> [String: Any] {
        var result = values
        if values[key] == nil {
            // Old app-specific sharing is not consent to expand an existing user's public inventory.
            result[key] = !existingInstallation && !legacyKeys.contains(where: { values[$0] != nil })
        } else if storedEnabled(in: values) == nil { result[key] = false }
        for key in legacyKeys { result[key] = nil }
        return result
    }
}
