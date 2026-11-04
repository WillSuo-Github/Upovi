import SwiftUI
import UpoviCore

struct UnattendedSettingsView: View {
    @Bindable var store: AppStore
    @State private var search = ""
    private var applications: [InstalledApp] {
        store.apps.filter { app in
            (try? UnattendedGrant(application: app, channel: store.releaseChannel(for: app))) != nil &&
                (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        Form {
            Section {
                Toggle("启用无人值守更新", isOn: Binding(get: { store.unattendedState.enabled }, set: { _ = store.setUnattendedEnabled($0) }))
                    .accessibilityIdentifier("unattended-enabled")
                LabeledContent("已授权的应用", value: store.unattendedState.grants.count.formatted())
                Button("检查并执行已授权更新") { store.refreshAll(allowUnattended: true) }
                    .disabled(!store.unattendedState.enabled || store.operationBusy || store.unattendedState.grants.isEmpty)
                    .accessibilityIdentifier("run-unattended-updates")
                if store.unattendedUpdating {
                    Button("停止自动更新") { store.unattendedTask?.cancel() }
                    Text("正在处理已授权应用；已开始的文件替换会安全完成。")
                }
            } header: { Text("无人值守更新") } footer: {
                Text("默认关闭。仅更新逐个授权、未运行、具有可验证下载且无需管理员权限的应用。不会自动处理 App Store、PKG、全局工具或 Upovi 自身；失败的同一版本会等待 24 小时再自动尝试。")
            }
            Section {
                Text("启用后，Upovi 运行期间会按通用设置中的检查间隔执行；休眠或退出后暂停。旧主应用保留在历史与恢复中。")
                Button("查看自动更新记录") { store.historySection = .automatic; store.section = .history }
            } header: { Text("运行与记录") }
            Section {
                TextField("筛选应用", text: $search).accessibilityIdentifier("unattended-app-search")
                ForEach(applications) { app in
                    Toggle(isOn: Binding(get: { store.unattendedState.grant(for: app, channel: store.releaseChannel(for: app)) != nil }, set: { store.setUnattendedAllowed($0, for: app) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(store.releaseChannel(for: app) == .beta ? String(localized: "Beta 与预发布") : String(localized: "正式版"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text(app.name + " · " + (store.releaseChannel(for: app) == .beta ? String(localized: "Beta 与预发布") : String(localized: "正式版"))))
                    .accessibilityIdentifier("unattended-allow-" + app.bundleID)
                }
            } header: { Text("逐个授权应用") } footer: {
                Text("授权绑定应用路径、开发者和渠道。切换渠道会撤销自动更新授权；忽略、跳过和稍后提醒规则仍然生效。")
            }
            Section {
                if store.sourceResults.values.contains(where: { result in result.checks.contains { $0.source == .appStoreNative && $0.issue?.code == 505 } }) {
                    Text("系统拒绝原生商店刷新（505）。").foregroundStyle(.secondary)
                }
                Button("打开 App Store 刷新") { store.open(URL(string: "macappstore://showUpdatesPage")) }
                Text("Upovi 会尝试原生只读刷新。若系统拒绝第三方访问，将保持未确认状态；不会通过启动再取消下载来探测更新。")
            } header: { Text("商店更新") }
        }.formStyle(.grouped)
    }
}

struct UnattendedHistoryView: View {
    @Bindable var store: AppStore
    var body: some View {
        if store.unattendedState.history.isEmpty {
            ContentUnavailableView("尚无自动更新记录", systemImage: "arrow.triangle.2.circlepath", description: Text("启用并逐个授权应用后，自动更新结果会出现在这里。"))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(store.unattendedState.history) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(record.application.name).font(.headline)
                            Spacer()
                            Text(record.phase.title).foregroundStyle(.secondary)
                        }
                        Text(record.application.version + " → " + record.version + (record.channel == .beta ? " · Beta" : ""))
                        Text(record.detail).font(.callout).foregroundStyle(.secondary)
                        Text(record.startedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }.card(padding: 14)
                }
            }
        }
    }
}

private extension UnattendedUpdateRecord.Phase {
    var title: String {
        switch self {
        case .preparing: String(localized: "正在准备")
        case .installing: String(localized: "正在安装")
        case .installed: String(localized: "已安装")
        case .current: String(localized: "无需更新")
        case .deferred: String(localized: "已推迟")
        case .failed: String(localized: "失败")
        case .cancelled: String(localized: "已取消")
        case .interrupted: String(localized: "已中断")
        }
    }
}
