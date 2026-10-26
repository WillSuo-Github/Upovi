import Foundation
import UpoviCore

extension AppStore {
    func manageAdministratorBackup(_ attempt: AdministratorInstallAttempt, cleanup: Bool) {
        guard !installationBusy, !refreshing, !checking, !scanning, !SelfUpdateService.shared.sessionInProgress else { return }
        installing = true; canCancelInstallation = false
        installationProgress = cleanup ? "正在请求管理员授权以清理保留数据…" : "正在核对管理员备份…"
        installationTask = Task {
            defer { installing = false }
            do {
                let plan = AdministratorInstallPlan(id: attempt.id, operation: cleanup ? .discardBackup : .inspect,
                    application: attempt.plan.application, version: attempt.plan.version, build: attempt.plan.build)
                try await administrator.perform(plan)
                installationProgress = cleanup ? "管理员保留数据已清理，事务记录已保留" : "管理员备份状态已核对"
            } catch { errorMessage = "管理员备份操作未完成；原有事务记录已保留，请核对状态：\(error.localizedDescription)" }
        }
    }
}
