import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct UpoviApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    @ObservedObject private var updater = SelfUpdateService.shared

    var body: some Scene {
        WindowGroup("Upovi", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 650)
                .task { [store] in updater.installationBusy = { [weak store] in store?.installationBusy == true } }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查 Upovi 自身更新…") { updater.check() }.disabled(!updater.canCheck || store.installationBusy)
            }
            CommandMenu("导航") {
                Button("可用更新") { store.section = .updates }.keyboardShortcut("1", modifiers: .command)
                Button("全部应用") { store.section = .all }.keyboardShortcut("2", modifiers: .command)
                Button("下载") { store.section = .downloads }.keyboardShortcut("3", modifiers: .command)
                Button("历史与恢复") { store.section = .history }.keyboardShortcut("4", modifiers: .command)
                Button("P2P 网络") { store.section = .community }.keyboardShortcut("5", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("刷新并检查全部应用") { store.refreshAll() }.keyboardShortcut("r")
                    .disabled(store.operationBusy)
                Button("全部更新…") { store.reviewAllUpdates() }.keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(store.operationBusy || store.updateCount == 0)
                Button("同步 P2P 记录") { store.beginSync() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!store.networkEnabled || store.syncing)
            }
            CommandGroup(after: .help) {
                Button("预览并导出诊断报告…") { store.diagnosticsPresentation = store.diagnosticSnapshot() }
            }
        }
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            Image(systemName: store.updateCount > 0 ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
            if store.updateCount > 0 { Text(store.updateCount.formatted()) }
        }
        Settings { SettingsView(store: store) }
    }
}

private struct MenuBarContent: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let updates = store.apps.filter { !store.ignored.contains($0.bundleID) && store.assessment(for: $0).hasUpdate }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Text(updates.isEmpty ? "没有来源报告的更新" : "\(updates.count) 个应用有来源更新")
        if let date = store.lastChecked { Text("上次检查 \(date.relativeDescription)") }
        if !updates.isEmpty {
            Divider()
            ForEach(updates.prefix(8)) { app in
                Button("\(app.name)  \(app.version) → \(store.assessment(for: app).sourceUpdates.first?.version ?? "")") {
                    store.section = .updates; show()
                }
            }
            if updates.count > 8 { Button("还有 \(updates.count - 8) 个…") { store.section = .updates; show() } }
            Button("全部更新…") { store.reviewAllUpdates(); show() }
                .disabled(store.operationBusy)
        }
        Divider()
        Button(store.refreshing || store.checking ? "正在检查…" : "刷新并检查") { store.refreshAll() }.disabled(store.operationBusy)
        Button("打开 Upovi") { show() }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 Upovi") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
