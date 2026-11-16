import SwiftUI
import AppKit

/// Optional help for an actual failed write. This view never queries, requests or tests access.
struct AppManagementGuideView: View {
    let store: AppStore
    let context: AppManagementGuide
    let dismiss: () -> Void
    @State private var actionError: String?
    private var hasFailedUpdates: Bool { context == .accessDenied && store.appManagementRetryRecord != nil }
    private var installerFound: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/Helpers/UpoviStoreInstaller.app/Contents/MacOS/UpoviStoreInstaller").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: hasFailedUpdates ? "lock.trianglebadge.exclamationmark" : "info.circle")
                    .font(.system(size: 32)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用访问帮助").font(.title2.bold())
                    Text("直接确认更新即可，无需单独验证权限。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if hasFailedUpdates {
                Text("最近一次更新被系统拒绝写入。这是失败记录，不代表当前权限未开启。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-management-write-denied")
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: installerFound ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.title3).foregroundStyle(installerFound ? .green : .orange).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("安装器组件").font(.callout.weight(.semibold))
                            Text(installerFound ? "已找到" : "未找到").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Upovi Installer / UpoviStoreInstaller").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("定位安装器") {
                        actionError = store.revealAppManagementInstaller() ? nil : String(localized: "未找到安装器，请使用完整的 Upovi 应用包。")
                    }.accessibilityIdentifier("app-management-reveal-installer")
                }.padding(.vertical, 16)
                Divider().padding(.leading, 48)
                HStack(spacing: 12) {
                    Image(systemName: "gearshape").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("应用程序管理").font(.callout.weight(.semibold))
                        Text("仅在更新提示访问被拒绝时检查此设置。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("打开设置") {
                        actionError = store.openAppManagementSettings() ? nil : String(localized: "无法打开系统设置，请手动前往“隐私与安全 → 应用程序管理”。")
                    }.accessibilityIdentifier("app-management-open-settings")
                }.padding(.vertical, 16)
            }
            .padding(.horizontal, 16).background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text("系统开关已开启时，无需反复切换。仍然失败可从设置导出诊断信息。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("系统设置 → 隐私与安全 → 应用程序管理。找不到安装器时，可定位后用“+”添加。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionError {
                Text(actionError).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-management-action-error")
            }
            Divider()
            HStack {
                Button("关闭", action: dismiss).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("app-management-dismiss")
                Spacer()
                if hasFailedUpdates {
                    Button("重新检查受阻项…") { dismiss(); store.reviewAppManagementBlockedUpdates() }
                        .disabled(store.operationBusy)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("app-management-review-retry")
                }
            }
        }
        .padding(28).frame(width: 610)
        .accessibilityIdentifier("app-management-guide")
    }
}

struct AppManagementNotice: View {
    let store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("此前失败的更新待重试").font(.callout.weight(.semibold))
                Text("可直接重新检查并确认更新，无需单独验证权限。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("访问帮助…") { store.presentAppManagementHelp() }
                .disabled(store.installationBusy).buttonStyle(PillButtonStyle()).fixedSize()
            Button("重新检查受阻项…") { store.reviewAppManagementBlockedUpdates() }
                .disabled(store.operationBusy || store.appManagementRetryRecord == nil)
                .buttonStyle(PillButtonStyle()).fixedSize()
        }
        .padding(16).modifier(UpdatesSurface()).accessibilityIdentifier("app-management-notice")
    }
}
