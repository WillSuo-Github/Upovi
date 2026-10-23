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

    var body: some Scene {
        WindowGroup("Upovi", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("重新扫描应用") { Task { await store.scan() } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("检查更新") { store.beginChecking() }.keyboardShortcut("r")
                    .disabled(store.checking || store.scanning)
                Button("同步 P2P 记录") { store.beginSync() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!store.networkEnabled || store.syncing)
            }
        }
        MenuBarExtra("Upovi", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarContent(store: store)
        }
        Settings { SettingsView(store: store) }
    }
}

private struct MenuBarContent: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(store.updateCount) 个应用有更新或线索")
        Button("打开 Upovi") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.checking ? "正在检查…" : "检查更新") { store.beginChecking() }.disabled(store.checking || store.scanning || store.installing)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 Upovi") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
