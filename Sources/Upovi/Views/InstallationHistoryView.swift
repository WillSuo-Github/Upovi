import SwiftUI
import AppKit
import UpoviCore

struct InstallationHistoryView: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BatchHistoryView(store: store)
                Divider()
                if !store.administrator.attempts.isEmpty {
                    Text("管理员安装与主应用恢复").font(.headline)
                    Text("只恢复主应用，安装脚本和其他系统变更不会回滚。取消授权的尝试可能没有生成系统备份。").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.administrator.attempts) { attempt in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(attempt.plan.application.name).font(.headline)
                            Text("\(attempt.plan.application.version) → \(attempt.plan.version)").font(.caption)
                            Text(administratorState(attempt.state)).font(.caption).foregroundStyle(.secondary)
                            if attempt.state != "restored" {
                                Button("恢复主应用…") { store.administratorRestoreConfirmation = attempt }.disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                            }
                        }
                    }
                    Divider()
                }
                Text("安装与恢复").font(.headline)
                if store.installationReceipts.isEmpty { Text("尚无安装记录").foregroundStyle(.secondary) }
                ForEach(store.installationReceipts) { receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(receipt.application.name).font(.headline)
                        Text("\(receipt.application.version) → \(receipt.newVersion) · \(receipt.date.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(stateLabel(receipt.state)).font(.caption)
                        if let bytes = store.backupSizes[receipt.id] {
                            Text("备份占用：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let path = receipt.retainedPath ?? ([.prepared, .backedUp, .failed].contains(receipt.state) ? receipt.backupPath : nil), FileManager.default.fileExists(atPath: path) {
                            HStack {
                                if receipt.state != .restored {
                                    Button("恢复旧版本…") { store.restoreConfirmation = receipt }.disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                                }
                                Button("查看副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                if receipt.retainedPath != nil {
                                    Button("清理备份…", role: .destructive) { store.backupDeletionConfirmation = receipt }.disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                                        .accessibilityIdentifier("cleanup-backup-\(receipt.id)")
                                }
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                Text("最近检测").font(.headline)
                if store.checkHistory.isEmpty { Text("尚无检测记录").foregroundStyle(.secondary) }
                ForEach(store.checkHistory) { entry in
                    HStack {
                        Text(entry.date, style: .date); Text(entry.date, style: .time)
                        Spacer()
                        Text("\(entry.applications) 个应用 · \(entry.updates) 个更新 · \(entry.failed) 项未完整检查")
                    }.font(.caption)
                }
            }.padding(24)
        }.task { await store.refreshInstallations() }
    }
    private func stateLabel(_ state: InstallationReceipt.State) -> String {
        switch state {
        case .prepared: "安装尚未完成，请检查恢复备份"
        case .backedUp: "安装中断，旧版本备份已保留"
        case .installed: "已安装，旧版本备份已保留"
        case .restored: "旧版本已恢复"
        case .failed: "安装未完成"
        case .backupDiscarded: "保留副本已清理"
        }
    }
    private func administratorState(_ state: String) -> String {
        switch state {
        case "installed": "安装完成，受保护的主应用备份已保留"
        case "restored": "主应用已恢复，其他系统改动未回滚"
        case "awaitingAuthorization": "授权或安装可能中断，请检查恢复选项"
        default: "安装未完成或授权已取消；恢复时会核对系统备份"
        }
    }
}
