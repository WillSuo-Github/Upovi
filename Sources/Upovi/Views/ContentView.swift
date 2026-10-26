import SwiftUI
import UpoviCore
import AppKit

struct ContentView: View {
    @Bindable var store: AppStore

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .overlay(alignment: .bottom) { ActivityPill(store: store).padding(.bottom, 16) }
        }
        .tint(Theme.accent)
        .searchable(text: $store.search, placement: .toolbar, prompt: "搜索应用或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.refreshAll() } label: { Label("刷新并检查", systemImage: "arrow.clockwise") }
                    .disabled(store.operationBusy)
                    .help("重新扫描全部应用，然后检查全部应用的更新（⌘R）")
                    .accessibilityIdentifier("refresh-all-apps")
            }
        }
        .task {
            if store.apps.isEmpty { await store.scan() }
            if store.networkEnabled { store.beginSync() }
        }
        .onChange(of: store.visibleApps.map(\.id)) { _, ids in
            if store.section == .all, !ids.contains(store.selection ?? "") { store.selection = ids.first }
        }
        .task { store.downloadCenter.start(); store.startMonitoring() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in store.recoverNetwork(reason: "wake") }
        .sheet(isPresented: $store.installationConfirmation, onDismiss: {
            if !store.installing { store.discardInstallation() }
        }) { InstallationConfirmationView(store: store) }
        .sheet(isPresented: $store.bulkUpdatePresented) { BulkUpdateView(store: store) }
        .sheet(item: $store.diagnosticsPresentation) { DiagnosticsView(snapshot: $0) }
        .sheet(item: $store.restoreConfirmation) { receipt in
            ConfirmationSheet(symbol: "clock.arrow.circlepath", title: "恢复 \(receipt.application.name)？",
                message: "将关闭应用并恢复到 \(receipt.application.version)。当前版本会保留在同一目录，应用的文稿和设置不会被此操作主动修改。",
                detail: "应用自身的数据格式可能不支持降级，请先保存工作。", confirmTitle: "恢复旧版本",
                cancel: { store.restoreConfirmation = nil },
                confirm: { store.restoreConfirmation = nil; store.restoreInstallation(receipt) })
        }
        .sheet(item: $store.backupDeletionConfirmation) { receipt in
            ConfirmationSheet(symbol: "trash", tone: .danger, title: "清理 \(receipt.application.name) 的保留副本？",
                message: "保留副本将移到废纸篓，清理后将无法使用这份副本恢复。当前应用、文稿和设置会保留。",
                confirmTitle: "移到废纸篓", destructive: true,
                cancel: { store.backupDeletionConfirmation = nil },
                confirm: { store.backupDeletionConfirmation = nil; store.discardBackup(receipt) })
        }
        .sheet(item: $store.administratorRestoreConfirmation) { attempt in
            ConfirmationSheet(symbol: "lock.rotation", tone: .warning, title: "恢复 \(attempt.plan.application.name) 的主应用？",
                message: "将请求管理员授权，从受保护的事务备份恢复安装前的主应用。",
                detail: "PKG 脚本、系统服务、驱动和数据变更不会因此撤销。", confirmTitle: "授权并恢复主应用",
                cancel: { store.administratorRestoreConfirmation = nil },
                confirm: { store.administratorRestoreConfirmation = nil; store.restoreAdministratorInstallation(attempt) })
        }
        .sheet(item: $store.administratorCleanupConfirmation) { attempt in
            ConfirmationSheet(symbol: "lock.trianglebadge.exclamationmark", tone: .danger, title: "清理 \(attempt.plan.application.name) 的管理员备份？",
                message: "将请求管理员授权，永久删除这个已完成事务的主应用副本、安装包和展开数据。清理后无法通过此事务恢复。当前应用和事务记录会保留。",
                detail: "中断、失败或当前应用身份／版本不匹配的事务会被拒绝清理。", path: attempt.plan.application.path,
                confirmTitle: "授权并永久清理", destructive: true, confirmIdentifier: "confirm-admin-backup-cleanup",
                cancel: { store.administratorCleanupConfirmation = nil },
                confirm: { store.administratorCleanupConfirmation = nil; store.manageAdministratorBackup(attempt, cleanup: true) })
        }
        .alert("Upovi", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    @ViewBuilder private var detail: some View {
        switch store.section ?? .all {
        case .updates: UpdatesView(store: store)
        case .all: LibraryView(store: store)
        case .downloads: DownloadTasksView(store: store)
        case .history: InstallationHistoryView(store: store)
        case .community: CommunityView(store: store)
        }
    }
}

private struct Sidebar: View {
    @Bindable var store: AppStore

    var body: some View {
        // Keep row identity and selection the same type; detail rendering uses this selection too.
        List<AppSection, _>(selection: $store.section) {
            Section {
                ForEach([AppSection.updates, .all, .downloads, .history], id: \.self) { section in
                    item(section, badge: badge(for: section))
                        .tag(section)
                }
            }
            Section("社区") {
                Button { store.section = .community } label: {
                    HStack {
                        Label(AppSection.community.rawValue, systemImage: AppSection.community.symbol)
                        Spacer()
                        Circle().fill(store.networkEnabled ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            .help(store.networkEnabled ? "P2P 已开启" : "P2P 已关闭")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(AppSection.community)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func item(_ section: AppSection, badge: Int) -> some View {
        // Activate the same state used by the detail column, including accessibility presses.
        Button { store.section = section } label: {
            Label(section.rawValue, systemImage: section.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .badge(badge)
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .updates: store.updateCount
        case .downloads: store.downloadCenter.records.filter { $0.state.active }.count
        default: 0
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 6)
            HStack(spacing: 6) {
                Image(systemName: store.networkAvailable ? "checkmark.icloud" : "icloud.slash")
                    .foregroundStyle(store.networkAvailable ? Color.secondary : Color.orange)
                Group {
                    if store.checking { Text("正在检查 \(store.completedChecks)/\(store.apps.count)") }
                    else if let date = store.lastChecked { Text("上次检查 \(date.relativeDescription)") }
                    else { Text("尚未检查更新") }
                }.lineLimit(1)
            }
            if !store.networkAvailable { Text("网络不可用，联网后恢复检查").foregroundStyle(.orange) }
            Text("\(store.apps.count) 个本机应用").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
}

/// Floating progress for scans, checks and installations, visible from every section.
private struct ActivityPill: View {
    let store: AppStore

    var body: some View {
        Group {
            if store.scanning || store.checking || store.installing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.callout).monospacedDigit().lineLimit(1)
                    if store.checking || store.refreshing {
                        Button("取消") { store.cancelChecking() }.buttonStyle(.link)
                    }
                    if store.installing {
                        if store.bulkUpdating { Button("查看进度") { store.bulkUpdatePresented = true }.buttonStyle(.link) }
                        else if store.canCancelInstallation { Button("取消下载") { store.cancelInstallation() }.buttonStyle(.link) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: store.scanning || store.checking || store.installing)
    }

    private var message: String {
        if store.scanning { return "正在扫描应用…" }
        if store.checking { return "正在检查更新 \(store.completedChecks)/\(store.apps.count)" }
        return store.installationProgress.isEmpty ? "正在处理更新…" : store.installationProgress
    }
}
