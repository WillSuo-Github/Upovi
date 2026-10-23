import SwiftUI
import UpoviCore
import AppKit

struct ContentView: View {
    @Bindable var store: AppStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.section) {
                Section("应用") {
                    sidebarItem(.updates, count: store.updateCount)
                    sidebarItem(.all, count: store.apps.count)
                    sidebarItem(.ignored, count: store.ignored.count)
                }
                Section("发现") { sidebarItem(.community, count: store.discoveredPublishers.count) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Upovi", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Text("开源 · 原生 · 让应用常新").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle().fill(store.networkEnabled ? Color.accentColor : Color.secondary).frame(width: 6, height: 6)
                        Text(store.networkEnabled ? "P2P 已启用" : "P2P 已关闭").font(.caption)
                    }
                    SettingsLink { Text("设置…").font(.caption) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            if store.section == .community {
                CommunityView(store: store)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        AppTable(store: store)
                        Divider()
                        footer
                    }.frame(minWidth: 430)
                    AppDetailView(store: store).frame(minWidth: 270, idealWidth: 310, maxWidth: 360)
                }
            }
        }
        .searchable(text: $store.search, prompt: "搜索应用或 Bundle ID")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await store.scan() } } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                    .disabled(store.scanning || store.checking || store.syncing).help("重新扫描应用目录")
                Button { store.beginChecking() } label: { Label("检查更新", systemImage: "arrow.down.circle") }
                    .disabled(store.scanning || store.checking || store.installing || store.apps.isEmpty)
                if store.section == .community {
                    Button { store.beginSync() } label: { Label("同步 P2P", systemImage: "network") }
                        .disabled(!store.networkEnabled || store.syncing || store.scanning)
                }
            }
        }
        .task {
            if store.apps.isEmpty { await store.scan() }
            if store.networkEnabled { store.beginSync() }
        }
        .onChange(of: store.visibleApps.map(\.id)) { _, ids in
            if !ids.contains(store.selection ?? "") { store.selection = ids.first }
        }
        .task { store.startMonitoring() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in store.recoverNetwork() }
        .sheet(isPresented: $store.installationConfirmation, onDismiss: {
            if !store.installing { store.discardInstallation() }
        }) { InstallationConfirmationView(store: store) }
        .sheet(item: $store.restoreConfirmation) { receipt in
            VStack(alignment: .leading, spacing: 18) {
                Text("恢复 \(receipt.application.name)？").font(.title2.bold())
                Text("将关闭应用并恢复到 \(receipt.application.version)。当前版本会保留在同一目录，应用的文稿和设置不会被此操作主动修改。")
                Text("应用自身的数据格式可能不支持降级，请先保存工作。").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("取消") { store.restoreConfirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("恢复旧版本") { store.restoreConfirmation = nil; store.restoreInstallation(receipt) }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 480)
        }
        .alert("Upovi", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func sidebarItem(_ section: AppSection, count: Int) -> some View {
        HStack {
            Label(section.rawValue, systemImage: section.symbol)
            Spacer()
            Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.tag(section)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.section?.rawValue ?? "全部应用").font(.title2.bold())
                Text(store.section == .updates ? "来源更新与社区线索分别标记" : "扫描本机应用，选择需要关注的更新")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.visibleApps.count)").font(.title2.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(22)
    }

    private var footer: some View {
        HStack {
            if store.scanning || store.checking || store.installing { ProgressView().controlSize(.small) }
            Text(store.scanning ? "正在扫描应用…" : store.checking ? "检查中 \(store.completedChecks)/\(store.apps.count)" : "\(store.apps.count) 个本机应用 · \(store.updateCount) 个有更新或线索")
            if store.checking { Button("取消检测") { store.cancelChecking() }.buttonStyle(.link) }
            if store.installing {
                Text(store.installationProgress)
                Button("取消") { store.cancelInstallation() }.buttonStyle(.link)
            }
            Spacer()
            if let date = store.lastChecked { Text(date, style: .time) }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
    }
}
