import SwiftUI

struct AppManagementGuideView: View {
    let store: AppStore
    let context: AppManagementGuide
    let dismiss: () -> Void
    @State private var settingsOpened = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield").font(.system(size: 32)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(context == .permissionRequired ? "需要应用程序管理权限" : "允许 Upovi 更新应用")
                        .font(.title2.bold())
                    Text("授权由你决定，检查更新不需要这项权限。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if context == .permissionRequired {
                Label("macOS 阻止了安装器修改应用。已完成的更新会保留，受阻项可在设置权限后重新检查。", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("替换受保护的应用时，macOS 可能要求应用程序管理权限。现在设置可以减少更新中断，也可以稍后再设置。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                step(1, title: String(localized: "打开应用程序管理"), detail: String(localized: "系统设置 → 隐私与安全 → 应用程序管理。"))
                step(2, title: String(localized: "允许 Upovi Installer"), detail: String(localized: "商店安装器可能显示为 Upovi Installer 或 UpoviStoreInstaller。请允许对应的项目；更新其他应用时，系统也可能要求允许 Upovi。"))
                step(3, title: String(localized: "没有看到安装器？"), detail: String(localized: "点击下方按钮在 Finder 中找到安装器，再用权限列表的“+”添加它。"))
                Button("在 Finder 中显示安装器") {
                    actionError = store.revealAppManagementInstaller() ? nil : String(localized: "未找到安装器，请使用完整的 Upovi 应用包。")
                }
                .accessibilityIdentifier("app-management-reveal-installer")
                .padding(.leading, 36)
            }
            .padding(18).background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text(context == .permissionRequired
                 ? "设置后返回 Upovi，点击“重新检查受阻项”。你确认更新后才会再次尝试安装。"
                 : "设置后返回 Upovi 即可继续。也可以稍后从“设置 → 扫描与安装”打开权限引导。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionError { Text(actionError).font(.callout).foregroundStyle(.red).accessibilityIdentifier("app-management-action-error") }
            Divider()
            HStack {
                Button(settingsOpened ? "继续使用" : "稍后设置", action: dismiss).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("app-management-dismiss")
                Spacer()
                if context == .permissionRequired, store.appManagementRetryRecord != nil {
                    Button("重新检查受阻项…") { store.reviewAppManagementBlockedUpdates() }
                        .disabled(store.operationBusy).accessibilityIdentifier("app-management-review-retry")
                }
                Button("打开系统设置") {
                    let opened = store.openAppManagementSettings()
                    settingsOpened = settingsOpened || opened
                    actionError = opened ? nil : String(localized: "无法打开系统设置，请手动前往“隐私与安全 → 应用程序管理”。")
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("app-management-open-settings")
            }
        }
        .padding(28).frame(width: 580)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("app-management-guide")
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted()).font(.callout.bold()).foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24).background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AppManagementNotice: View {
    let store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("部分应用需要应用程序管理权限").font(.callout.weight(.semibold))
                Text("先允许 Upovi Installer，再重新检查受阻项。已完成的更新不受影响。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("设置权限…") { store.presentAppManagementHelp() }.disabled(store.installationBusy)
                .buttonStyle(PillButtonStyle()).fixedSize()
        }
        .padding(16).modifier(UpdatesSurface()).accessibilityIdentifier("app-management-notice")
    }
}
