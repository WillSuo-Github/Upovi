import Foundation
import UserNotifications
import UpoviCore

@MainActor
final class NotificationService {
    private var seen = Set(UserDefaults.standard.stringArray(forKey: "notifiedUpdatesV1") ?? [])
    func requestAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func announce(_ apps: [InstalledApp], results: [String: SourceResult], ignored: Set<String>) async {
        let updates = apps.filter { app in
            guard !ignored.contains(app.bundleID) else { return false }
            return (results[app.id]?.candidates ?? []).contains { !seen.contains(app.bundleID + ":" + $0.version + ":" + $0.build) }
        }
        guard !updates.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "发现 \(updates.count) 个应用更新"
        content.body = updates.prefix(3).map(\.name).joined(separator: "、")
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
            for app in updates { for candidate in results[app.id]?.candidates ?? [] { seen.insert(app.bundleID + ":" + candidate.version + ":" + candidate.build) } }
            if seen.count > 1000 { seen = Set(seen.sorted().suffix(1000)) }
            UserDefaults.standard.set(Array(seen), forKey: "notifiedUpdatesV1")
        } catch { }
    }
}
