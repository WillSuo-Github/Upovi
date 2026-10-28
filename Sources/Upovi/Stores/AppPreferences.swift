import Foundation
import UpoviCore

@MainActor
final class AppPreferences {
    static let shared = AppPreferences()
    private let storage: SettingsFile
    private var values: [String: Any] = [:]
    private(set) var loadFailure: String?
    var onFailure: ((String) -> Void)?
    private static let migratedKeys = [GlobalP2PSettings.key, "lastSectionV1", "publicDiscoveryEnabledV2", "publicSharingEnabledV2", "selectedBundles",
        "ignoredBundles", "automaticChecksV1", "checkIntervalV1", "notificationsV1", "sourceOverridesV1", "checkHistoryV1",
        "publicPublisherCacheV2", "notifiedUpdatesV1"]

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Upovi/settings-v1.plist"), migrateUserDefaults: Bool = true) {
        storage = SettingsFile(url: url)
        do {
            let saved = try storage.read()
            if let saved { values = saved }
            else if migrateUserDefaults {
                for key in Self.migratedKeys { values[key] = UserDefaults.standard.object(forKey: key) }
            }
            let needsMigration = GlobalP2PSettings.storedEnabled(in: values) == nil
                || GlobalP2PSettings.legacyKeys.contains(where: { values[$0] != nil })
            if needsMigration {
                values = GlobalP2PSettings.migrated(values, existingInstallation: saved != nil || !values.isEmpty)
                try storage.write(values)
            }
        } catch { values = [:]; loadFailure = String(localized: "设置无法读取或保存，P2P 已保持关闭。请检查 Upovi 的应用支持目录，原有损坏文件不会被覆盖。") }
    }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    @discardableResult
    func set(_ value: Any?, forKey key: String) -> Bool {
        guard loadFailure == nil else { onFailure?(loadFailure!); return false }
        var next = values; next[key] = value
        do { try storage.write(next); values = next; return true }
        catch { onFailure?(String(localized: "设置保存失败，重启后可能无法恢复本次更改。请检查 Upovi 应用支持目录的可写性。")); return false }
    }
}
