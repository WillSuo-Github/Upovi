import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginItemService {
    private(set) var status = SMAppService.mainApp.status
    private(set) var errorMessage: String?
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = String(localized: "登录启动设置未完成：\(error.localizedDescription)")
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
