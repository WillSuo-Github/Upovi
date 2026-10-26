import SwiftUI
import UpoviCore

struct AdministratorBackupRow: View {
    let store: AppStore
    let attempt: AdministratorInstallAttempt
    private var busy: Bool { store.installationBusy || store.refreshing || store.checking || store.scanning }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attempt.plan.application.name).font(.headline)
            Text(attempt.plan.application.path).font(.caption).textSelection(.enabled)
            Text("\(attempt.plan.application.version) → \(attempt.plan.version)").font(.caption)
            Text(status).font(.caption).foregroundStyle(.secondary)
            if let bytes = attempt.backupBytes {
                Text("保留数据占用（估算）：\(attempt.backupBytesIsLowerBound == true ? "至少 " : "")\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("核对管理员记录…") { store.manageAdministratorBackup(attempt, cleanup: false) }.disabled(busy)
                    .accessibilityIdentifier("inspect-admin-backup-\(attempt.id)")
                if AdministratorBackupCleaner.canRestore(attempt.state) {
                    Button("恢复主应用…") { store.administratorRestoreConfirmation = attempt }.disabled(busy)
                }
                if ["installed", "restored"].contains(attempt.state) || (attempt.state == "backupDiscarded" && attempt.cleanupComplete == false) {
                    Button("清理管理员备份…", role: .destructive) { store.administratorCleanupConfirmation = attempt }.disabled(busy)
                        .accessibilityIdentifier("cleanup-admin-backup-\(attempt.id)")
                }
            }
        }
    }
    private var status: String {
        switch attempt.state {
        case "installed": "安装完成，受保护的主应用备份已保留"
        case "restored": "主应用已恢复，其他系统改动未回滚"
        case "backupDiscarded": attempt.cleanupComplete == true ? "保留数据已清理，恢复已停用" : "清理未完成，恢复已停用；可继续清理残留"
        case "cleanupPending": "清理状态尚未确认，请先核对管理员记录"
        case "awaitingAuthorization": "授权或安装可能中断，请检查恢复选项"
        default: "安装未完成或授权已取消；恢复时会核对系统备份"
        }
    }
}
