import SwiftUI
import AppKit
import UpoviCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var notificationTestStatus = ""
    @State private var sendingTestNotification = false
    @State private var loginItem = LoginItemService()
    @ObservedObject private var updater = SelfUpdateService.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            Form {
                Section("启动") {
                    Toggle("登录时启动 Upovi", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                    if loginItem.needsApproval {
                        Text("需要在系统设置中允许 Upovi 登录启动。").font(.caption).foregroundStyle(.secondary)
                        Button("打开登录项设置") { loginItem.openSettings() }
                    }
                    if let error = loginItem.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
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
                    if !store.updatePolicy.skipped.isEmpty || !store.updatePolicy.deferredUntil.isEmpty {
                        Button("恢复所有跳过与稍后提醒") { store.clearUpdatePolicy() }
                    }
                }
                Section("应用扫描与安装") {
                    Text("扫描 /Applications 和 ~/Applications，不执行被扫描应用。当前识别 \(store.apps.count) 个应用。")
                    Text("支持验证后的 ZIP／DMG 应用更新，以及经负载检查的签名 PKG。管理员安装会显示系统授权窗口。App Store 应用可在 Upovi 内发起商店更新，可能需要 Apple 账户认证；商店更新不提供 Upovi 旧版备份或暂停。无法验证的其他安装包仍使用官方渠道。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("刷新并检查") { store.refreshAll() }.disabled(store.refreshing || store.scanning || store.checking || store.installationBusy)
                    ForEach(store.additionalScanDirectories, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button("移除") { store.setScanDirectories(store.additionalScanDirectories.filter { $0 != path }) }
                                .disabled(store.refreshing || store.scanning || store.checking || store.installationBusy)
                        }
                    }
                    Button("添加扫描目录…") { store.chooseScanDirectory() }
                        .disabled(store.refreshing || store.scanning || store.checking || store.installationBusy)
                }
                Section("诊断与反馈") {
                    Button("预览并导出诊断报告…") { store.diagnosticsPresentation = store.diagnosticSnapshot() }
                        .accessibilityIdentifier("open-diagnostics-report")
                    Text("先预览再保存。默认隐藏软件标识，不读取系统或管理员授权日志。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Upovi \(AppMetadata.displayVersion)") {
                    Text("SwiftUI · MIT License · macOS 14+")
                    Button("检查 Upovi 自身更新…") { updater.check() }.disabled(!updater.canCheck || store.installationBusy)
                    Toggle("自动检查 Upovi 自身更新", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                        .disabled(!updater.isConfigured)
                    if !updater.isConfigured { Text("开发命令行版本未配置自身更新，请使用完整应用包。").font(.caption).foregroundStyle(.secondary) }
                    Link("项目与问题反馈", destination: URL(string: "https://github.com/WillSuo-Github/Upovi")!)
                }
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                Section("P2P 网络") {
                    Toggle("启用 P2P 网络", isOn: Binding(get: { store.networkEnabled }, set: { store.setP2PEnabled($0) }))
                        .accessibilityIdentifier("global-p2p-toggle")
                    Text("首次使用默认开启。开启后，所有已扫描应用都会参与版本发现与公开共享，无需逐个选择；关闭后停止发现、发布和响应请求。")
                        .foregroundStyle(.secondary)
                    Text("已扫描：\(store.apps.count) 个应用；验签节点：\(store.discoveredPublishers.count) 个")
                    Text("公开信息包括应用标识、版本、构建号、分发渠道和自报 Team ID，任何人均可读取；节点也能看到 IP。不包含路径、用户名、设备名或安装包。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("关闭后，网络中已缓存的公开记录仍会按有效期过期，无法立即撤回。签名不能证明真实安装或官方发布。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(store.networkStatus).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("P2P", systemImage: "network") }
            InstallationHistoryView(store: store).tabItem { Label("记录与恢复", systemImage: "clock.arrow.circlepath") }
        }.frame(width: 660, height: 620)
        .sheet(item: $store.diagnosticsPresentation) { DiagnosticsView(snapshot: $0) }
        .onAppear { loginItem.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { loginItem.refresh() } }
        .sheet(item: $store.backupDeletionConfirmation) { receipt in
            VStack(alignment: .leading, spacing: 18) {
                Text("清理 \(receipt.application.name) 的保留副本？").font(.title2.bold())
                Text("保留副本将移到废纸篓，清理后将无法使用这份副本恢复。当前应用、文稿和设置会保留。")
                HStack {
                    Button("取消") { store.backupDeletionConfirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("移到废纸篓", role: .destructive) {
                        store.backupDeletionConfirmation = nil; store.discardBackup(receipt)
                    }
                }
            }.padding(28).frame(width: 480)
        }
        .sheet(item: $store.administratorRestoreConfirmation) { attempt in
            VStack(alignment: .leading, spacing: 18) {
                Text("恢复 \(attempt.plan.application.name) 的主应用？").font(.title2.bold())
                Text("将请求管理员授权，从受保护的事务备份恢复安装前的主应用。PKG 脚本、系统服务、驱动和数据变更不会因此撤销。")
                HStack {
                    Button("取消") { store.administratorRestoreConfirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("授权并恢复主应用") { store.administratorRestoreConfirmation = nil; store.restoreAdministratorInstallation(attempt) }
                }
            }.padding(28).frame(width: 480)
        }
        .sheet(item: $store.administratorCleanupConfirmation) { attempt in
            VStack(alignment: .leading, spacing: 18) {
                Text("清理 \(attempt.plan.application.name) 的管理员备份？").font(.title2.bold())
                Text(attempt.plan.application.path).font(.caption).textSelection(.enabled)
                Text("将请求管理员授权，永久删除这个已完成事务的主应用副本、安装包和展开数据。清理后无法通过此事务恢复。当前应用和事务记录会保留。")
                Text("中断、失败或当前应用身份／版本不匹配的事务会被拒绝清理。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("取消") { store.administratorCleanupConfirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("授权并永久清理", role: .destructive) {
                        store.administratorCleanupConfirmation = nil
                        store.manageAdministratorBackup(attempt, cleanup: true)
                    }.accessibilityIdentifier("confirm-admin-backup-cleanup")
                }
            }.padding(28).frame(width: 500)
        }
    }
}
