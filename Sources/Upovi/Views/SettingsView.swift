import SwiftUI
import AppKit
import UpoviCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @AppStorage("settingsTabV1") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(store: store).tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            ScanSettings(store: store).tabItem { Label("扫描与安装", systemImage: "square.grid.2x2") }.tag("scan")
            P2PSettings(store: store).tabItem { Label("P2P", systemImage: "point.3.connected.trianglepath.dotted") }.tag("p2p")
            AboutSettings(store: store).tabItem { Label("关于", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 600, height: 500)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: AppStore
    @State private var loginItem = LoginItemService()
    @State private var notificationTestStatus = ""
    @State private var sendingTestNotification = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动 Upovi", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    LabeledContent("需要在系统设置中允许 Upovi 登录启动。") { Button("打开登录项设置") { loginItem.openSettings() } }
                        .font(.caption)
                }
                if let error = loginItem.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("启动") }

            Section {
                Toggle("应用运行时定时检查更新", isOn: $store.automaticChecks)
                Picker("检查间隔", selection: $store.checkIntervalMinutes) {
                    Text("每 15 分钟").tag(15)
                    Text("每小时").tag(60)
                    Text("每 6 小时").tag(360)
                }.disabled(!store.automaticChecks)
            } header: { Text("自动检查") } footer: {
                Text("每次启动会自动扫描并检查一次；开启定时检查后，应用运行期间还会按间隔重复检查。休眠或退出应用会暂停定时检查。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $store.bulkConcurrency, in: BulkUpdateRunner.concurrencyRange) {
                    LabeledContent(String(localized: "同时下载和安装"), value: String(localized: "\(store.bulkConcurrency) 个应用"))
                }
                .disabled(store.bulkUpdating)
                .accessibilityIdentifier("bulk-concurrency")
            } header: { Text("批量更新") } footer: {
                Text("全部更新时最多同时处理的应用数。需要管理员授权或 App Store 的安装会依次进行，避免同时弹出多个系统授权窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("发现来源更新时通知我", isOn: Binding(get: { store.notificationsEnabled }, set: { enabled in
                    Task { await store.setNotifications(enabled) }
                }))
                LabeledContent {
                    Button("发送测试通知") {
                        sendingTestNotification = true
                        Task {
                            notificationTestStatus = await store.notifications.sendTest()
                            sendingTestNotification = false
                        }
                    }.disabled(!store.notificationsEnabled || sendingTestNotification)
                } label: {
                    Text(notificationTestStatus.isEmpty ? String(localized: "测试通知") : notificationTestStatus).foregroundStyle(notificationTestStatus.isEmpty ? .primary : .secondary)
                }
            } header: { Text("通知") } footer: {
                Text("社区版本仅作线索，不触发更新通知。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("跳过的版本") { Text("\(store.updatePolicy.skipped.count) 个").foregroundStyle(.secondary) }
                LabeledContent("稍后提醒的应用") { Text("\(store.updatePolicy.deferredUntil.count) 个").foregroundStyle(.secondary) }
                Button("恢复所有跳过与稍后提醒") { store.clearUpdatePolicy() }
                    .disabled(store.updatePolicy.skipped.isEmpty && store.updatePolicy.deferredUntil.isEmpty)
            } header: { Text("提醒规则") }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { loginItem.refresh() } }
    }
}

private struct ScanSettings: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section {
                ForEach(["/Applications", "~/Applications"], id: \.self) { path in
                    Label(path, systemImage: "folder.fill").foregroundStyle(.secondary)
                }
                ForEach(store.additionalScanDirectories, id: \.self) { path in
                    HStack {
                        Label(path, systemImage: "folder.badge.plus").textSelection(.enabled)
                        Spacer()
                        Button { store.setScanDirectories(store.additionalScanDirectories.filter { $0 != path }) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless).help("移除此目录").disabled(store.operationBusy)
                    }
                }
                Button { store.chooseScanDirectory() } label: { Label("添加扫描目录…", systemImage: "plus") }
                    .disabled(store.operationBusy)
            } header: { Text("扫描位置") } footer: {
                Text("当前识别 \(store.apps.count) 个应用。Upovi 只读取应用信息，不会运行被扫描的应用；更改目录后会自动重新扫描。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                capability("checkmark.shield", String(localized: "ZIP／DMG 应用更新"), String(localized: "下载后核对完整性、应用标识、开发者签名与 Gatekeeper，安装时保留旧版本。"))
                capability("shippingbox", String(localized: "签名 PKG"), String(localized: "检查安装负载后执行；管理员安装会显示系统授权窗口，脚本改动无法回滚。"))
                capability("bag", String(localized: "App Store 应用"), String(localized: "由 Upovi 发起商店更新，可能需要 Apple 账户认证；不提供旧版备份或暂停。"))
                capability("arrow.up.forward.app", String(localized: "其他安装包"), String(localized: "无法验证时，引导到官方来源更新。"))
            } header: { Text("支持的安装方式") }
        }.formStyle(.grouped)
        .listAnimation(store.additionalScanDirectories)
    }

    private func capability(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct P2PSettings: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.networkEnabled }, set: { store.setP2PEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 P2P 网络")
                        Text("所有已扫描应用都会参与版本发现与公开共享，无需逐个选择。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("global-p2p-toggle")
                LabeledContent("已扫描应用") { Text("\(store.apps.count) 个").monospacedDigit() }
                LabeledContent("验签节点") { Text("\(store.discoveredPublishers.count) 个").monospacedDigit() }
                LabeledContent("状态") { Text(store.networkStatus.components(separatedBy: "\n").first ?? "").foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            } footer: {
                Text("首次使用默认开启。关闭后停止发现、发布和响应请求。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                note("eye", String(localized: "公开信息包括应用标识、版本、构建号、分发渠道和自报 Team ID，任何人均可读取；节点也能看到 IP。"))
                note("eye.slash", String(localized: "不包含路径、用户名、设备名或安装包。"))
                note("clock.arrow.circlepath", String(localized: "关闭后，网络中已缓存的公开记录仍会按有效期过期，无法立即撤回。"))
                note("signature", String(localized: "签名不能证明真实安装或官方发布；社区报告不计入可用更新。"))
            } header: { Text("共享的内容") }
        }.formStyle(.grouped)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.callout).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }
}

private struct AboutSettings: View {
    @Bindable var store: AppStore
    @ObservedObject private var updater = SelfUpdateService.shared
    @State private var diagnostics: DiagnosticSnapshot?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Upovi").font(Theme.display(22))
                        Text("版本 \(AppMetadata.displayVersion)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text("开源 · 原生 · 让应用常新 — SwiftUI · MIT · macOS 14+").font(.caption).foregroundStyle(.tertiary)
                    }
                }.padding(.vertical, 4)
                Link(destination: URL(string: "https://github.com/WillSuo-Github/Upovi")!) { Label("项目主页与问题反馈", systemImage: "arrow.up.forward.square") }
            }

            Section {
                Toggle("自动检查 Upovi 自身更新", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    .disabled(!updater.isConfigured)
                Button("检查 Upovi 自身更新…") { updater.check() }.disabled(!updater.canCheck || store.installationBusy)
            } header: { Text("Upovi 更新") } footer: {
                if !updater.isConfigured { Text("开发命令行版本未配置自身更新，请使用完整应用包。").font(.caption).foregroundStyle(.secondary) }
            }

            Section {
                Button("预览并导出诊断报告…") { diagnostics = store.diagnosticSnapshot() }
                    .accessibilityIdentifier("open-diagnostics-report")
            } header: { Text("诊断") } footer: {
                Text("先预览再保存，不会自动上传。默认隐藏软件标识，不读取系统或管理员授权日志。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $diagnostics) { DiagnosticsView(snapshot: $0) }
    }
}
