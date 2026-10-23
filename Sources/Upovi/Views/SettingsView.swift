import SwiftUI
import AppKit
import UpoviCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var notificationTestStatus = ""
    @State private var sendingTestNotification = false
    var body: some View {
        TabView {
            Form {
                Section("更新检测") {
                    Toggle("应用运行时自动检查更新", isOn: $store.automaticChecks)
                    Picker("检查间隔", selection: $store.checkIntervalMinutes) {
                        Text("15 分钟").tag(15)
                        Text("1 小时").tag(60)
                        Text("6 小时").tag(360)
                    }.disabled(!store.automaticChecks)
                    Toggle("发现来源更新时通知我", isOn: Binding(get: { store.notificationsEnabled }, set: { enabled in
                        Task { await store.setNotifications(enabled) }
                    }))
                    HStack {
                        Button("发送测试通知") {
                            sendingTestNotification = true
                            Task {
                                notificationTestStatus = await store.notifications.sendTest()
                                sendingTestNotification = false
                            }
                        }.disabled(!store.notificationsEnabled || sendingTestNotification)
                        if !notificationTestStatus.isEmpty { Text(notificationTestStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("休眠或退出应用会暂停检查；醒来后恢复网络连接。社区版本仅作线索，不触发安装或官方更新通知。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("应用扫描与安装") {
                    Text("扫描 /Applications 和 ~/Applications，不执行被扫描应用。当前识别 \(store.apps.count) 个应用。")
                    Text("支持通过完整性与同一开发者签名校验的 ZIP／DMG 应用更新。App Store、PKG、无完整性信息或需管理员权限的更新交给官方渠道。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重新扫描") { Task { await store.scan() } }.disabled(store.scanning || store.checking || store.syncing || store.installing)
                }
                Section("Upovi 0.3.1") {
                    Text("SwiftUI · MIT License · macOS 14+")
                    Link("项目与问题反馈", destination: URL(string: "https://github.com/WillSuo-Github/Upovi")!)
                }
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                Section("公网 DHT") {
                    Toggle("启用 P2P 检测", isOn: $store.networkEnabled)
                    Toggle("公开共享选中应用的版本", isOn: $store.sharingEnabled).disabled(!store.sharingEnabled && (!store.networkEnabled || store.syncing))
                    Text("按应用主题自动发现公网共享节点，无需交换邀请。公开共享默认关闭，开启后选中的版本信息可被任何人读取。")
                        .foregroundStyle(.secondary)
                    Text("检测范围：\(store.selectedBundles.count) 个应用；验签节点：\(store.discoveredPublishers.count) 个")
                    Text("关闭共享停止服务和续期，无法立即撤回已缓存的公开记录。签名只证明记录来源，不能证明真实安装或官方发布。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("P2P", systemImage: "network") }
            HistoryView(store: store).tabItem { Label("记录与恢复", systemImage: "clock.arrow.circlepath") }
        }.frame(width: 660, height: 550)
    }
}

private struct HistoryView: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("安装与恢复").font(.headline)
                if store.installationReceipts.isEmpty { Text("尚无安装记录").foregroundStyle(.secondary) }
                ForEach(store.installationReceipts) { receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(receipt.application.name).font(.headline)
                        Text("\(receipt.application.version) → \(receipt.newVersion) · \(receipt.date.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(stateLabel(receipt.state)).font(.caption)
                        if FileManager.default.fileExists(atPath: receipt.backupPath) {
                            HStack {
                                Button("恢复旧版本…") { store.restoreConfirmation = receipt }.disabled(store.installing)
                                Button("查看备份") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.backupPath)]) }
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
        }
    }
}
