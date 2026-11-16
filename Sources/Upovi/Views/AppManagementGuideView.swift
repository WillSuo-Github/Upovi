import SwiftUI
import AppKit

struct AppManagementGuideView: View {
    let store: AppStore
    let context: AppManagementGuide
    let dismiss: () -> Void
    @State private var settingsOpened = false
    @State private var actionError: String?
    private var verified: Bool { !store.appManagementAccessChecks.isEmpty && store.appManagementAccessChecks.allSatisfy(\.verified) }
    private var blocked: Bool { store.appManagementAccessChecks.contains { !$0.verified } }
    private var installerFound: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/Helpers/UpoviStoreInstaller.app/Contents/MacOS/UpoviStoreInstaller").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: verified ? "checkmark.shield.fill" : "lock.shield").font(.system(size: 32))
                    .foregroundStyle(verified ? .green : Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verified ? "上次应用写入访问成功" : "设置更新权限").font(.title2.bold())
                    Text("逐项查看状态，验证通过后再确认更新。检查更新无需授权。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                accessRow(title: String(localized: "安装器组件"), detail: "Upovi Installer / UpoviStoreInstaller",
                          symbol: installerFound ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                          tint: installerFound ? .green : .orange,
                          status: installerFound ? String(localized: "已找到") : String(localized: "未找到")) {
                    Button("定位安装器") {
                        actionError = store.revealAppManagementInstaller() ? nil : String(localized: "未找到安装器，请使用完整的 Upovi 应用包。")
                    }.accessibilityIdentifier("app-management-reveal-installer")
                }
                Divider().padding(.leading, 48)
                accessRow(title: String(localized: "应用程序管理"),
                          detail: String(localized: "在此处允许 Upovi 和 Upovi Installer。开关已开启仍报错时，请验证实际访问。"),
                          symbol: verified ? "checkmark.circle.fill" : (blocked ? "exclamationmark.circle.fill" : "circle.dashed"),
                          tint: verified ? .green : (blocked ? .orange : .secondary),
                          status: verified ? String(localized: "上次访问成功") : (blocked ? String(localized: "仍受阻") : String(localized: "待验证"))) {
                    Button("打开设置") { openSettings() }.accessibilityIdentifier("app-management-open-settings")
                }
            }
            .padding(.horizontal, 16).background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
            if store.appManagementAccessChecking {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在验证安装器访问…") }.font(.callout)
            }
            if !store.appManagementAccessChecks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.appManagementAccessChecks) { check in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: check.verified ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(check.verified ? .green : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(check.name).font(.callout.weight(.semibold))
                                Text(check.verified ? String(localized: "安装器写入测试通过") : (check.failure ?? String(localized: "访问未确认")))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("这是上次访问的记录，不代表实时系统权限。正常更新无需重复验证；发生新的访问失败时再检查。")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("app-management-access-results")
            }
            Text("验证会请求管理员授权，只创建并移除一个临时测试文件；不会下载、更新应用或修改购买凭据。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !verified {
                Text("系统设置 → 隐私与安全 → 应用程序管理。找不到安装器时，可定位后用“+”添加。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = actionError ?? store.appManagementAccessError {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-management-action-error")
            }
            Divider()
            HStack {
                Button(verified ? "关闭" : "稍后设置", action: dismiss).keyboardShortcut(.cancelAction)
                    .disabled(store.appManagementAccessChecking).accessibilityIdentifier("app-management-dismiss")
                Spacer()
                if context == .permissionRequired, store.appManagementRetryRecord != nil {
                    Button("重新检查受阻项…") { store.reviewAppManagementBlockedUpdates() }
                        .disabled(store.operationBusy || store.appManagementAccessChecking)
                        .accessibilityIdentifier("app-management-review-retry")
                }
                if verified {
                    Button("重新验证") { store.verifyAppManagementAccess() }
                        .disabled(store.operationBusy || store.appManagementAccessChecking)
                }
                Button(verified ? "完成" : "验证访问") {
                    if verified { dismiss() } else { store.verifyAppManagementAccess() }
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.operationBusy || store.appManagementAccessChecking)
                    .accessibilityIdentifier("app-management-verify-access")
            }
        }
        .padding(28).frame(width: 610)
        .interactiveDismissDisabled(store.appManagementAccessChecking)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if settingsOpened { store.appManagementAccessChecks = []; store.appManagementAccessCheckedAt = nil; settingsOpened = false }
        }
        .accessibilityIdentifier("app-management-guide")
    }

    private func openSettings() {
        let opened = store.openAppManagementSettings()
        settingsOpened = opened
        actionError = opened ? nil : String(localized: "无法打开系统设置，请手动前往“隐私与安全 → 应用程序管理”。")
    }

    private func accessRow<Actions: View>(title: String, detail: String, symbol: String, tint: Color, status: String,
                                         @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(title).font(.callout.weight(.semibold)); Text(status).font(.caption).foregroundStyle(tint) }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions().fixedSize()
        }.padding(.vertical, 16)
    }
}

struct AppManagementNotice: View {
    let store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.appManagementBlockedAccessVerified ? "checkmark.shield.fill" : "lock.trianglebadge.exclamationmark")
                .foregroundStyle(store.appManagementBlockedAccessVerified ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("此前失败的更新待重试").font(.callout.weight(.semibold))
                Text("历史失败不代表当前未授权。可直接重新检查并确认更新，无需重复验证权限。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("查看权限…") { store.presentAppManagementHelp() }
                .disabled(store.installationBusy).buttonStyle(PillButtonStyle()).fixedSize()
            Button("重新检查受阻项…") { store.reviewAppManagementBlockedUpdates() }
                .disabled(store.operationBusy || store.appManagementRetryRecord == nil)
                .buttonStyle(PillButtonStyle()).fixedSize()
        }
        .padding(16).modifier(UpdatesSurface()).accessibilityIdentifier("app-management-notice")
    }
}
