import Foundation
import UserNotifications
import UpoviCore
import OSLog

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "app.upovi.Upovi", category: "notifications")
    private var seen = Set(AppPreferences.shared.stringArray(forKey: "notifiedUpdatesV1") ?? [])
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    private func wasDelivered(_ id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.contains { $0.request.identifier == id })
            }
        }
    }
    func sendTest() async -> String {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upovi 通知测试")
        content.body = String(localized: "来源更新提醒已启用。社区版本仍只作为线索。")
        content.sound = .default
        let id = UUID().uuidString
        do {
            try await UNUserNotificationCenter.current().add(.init(identifier: id, content: content, trigger: nil))
            try await Task.sleep(for: .seconds(2))
            let delivered = await wasDelivered(id)
            logger.info("notification test submitted delivered=\(delivered)")
            return delivered ? String(localized: "测试通知已送达通知中心。") : String(localized: "测试通知已提交；若未显示，请检查系统通知与专注模式。")
        } catch { logger.error("notification test failed"); return String(localized: "测试通知发送失败，请检查通知权限。") }
    }
    func requestAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func allowReminder(for app: InstalledApp) {
        seen = seen.filter { !$0.hasPrefix(app.bundleID + ":") }
        AppPreferences.shared.set(Array(seen), forKey: "notifiedUpdatesV1")
    }
    func announce(_ apps: [InstalledApp], results: [String: SourceResult], ignored: Set<String>) async {
        let updates = UpdateAssessment.notificationBatch(apps: apps, results: results, ignored: ignored, seen: seen)
        guard !updates.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "发现 \(updates.count) 个应用更新")
        content.body = updates.prefix(3).map(\.app.name).joined(separator: "、")
        content.sound = .default
        do {
            let id = UUID().uuidString
            try await UNUserNotificationCenter.current().add(.init(identifier: id, content: content, trigger: nil))
            logger.info("update notification scheduled apps=\(updates.count)")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let delivered = await wasDelivered(id)
                logger.info("update notification delivery observed delivered=\(delivered)")
            }
            for update in updates { seen.formUnion(update.deduplicationKeys) }
            if seen.count > 1000 { seen = Set(seen.sorted().suffix(1000)) }
            AppPreferences.shared.set(Array(seen), forKey: "notifiedUpdatesV1")
        } catch { logger.error("update notification scheduling failed") }
    }
}
