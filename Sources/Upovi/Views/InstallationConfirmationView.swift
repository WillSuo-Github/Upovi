import SwiftUI

struct InstallationConfirmationView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let update = store.preparedUpdate {
                header(path: update.application.path, title: update.application.name, badge: "更新已验证",
                       from: update.application.version, to: update.replacement.version)
                checklist(["下载完整性", "应用标识与开发者签名", "嵌套代码签名与架构兼容", "macOS Gatekeeper 信任"])
                Label("安装会请求关闭应用，并保留旧版本以便在“历史与恢复”中恢复。请先保存正在编辑的文稿。", systemImage: "doc.badge.clock")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("使用管理员权限安装", isOn: $store.administratorInstallRequested)
                    if store.administratorInstallRequested {
                        Text("将显示 macOS 管理员授权窗口，并在系统事务目录保留主应用备份。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                buttons(confirm: "关闭应用并安装")
            } else if let package = store.preparedPackage {
                header(path: package.plan.application.path, title: package.plan.application.name, badge: "安装包签名已验证",
                       from: package.plan.application.version, to: package.plan.version)
                checklist(["下载完整性", "安装包开发者签名", "macOS Gatekeeper 信任"])
                Text("授权后将检查安装负载的应用身份，再由 Upovi 执行系统安装工具。").font(.callout)
                Label("PKG 可运行安装脚本并修改系统服务。Upovi 保留主应用备份，但恢复主应用不会撤销安装脚本、驱动或其他系统改动。请先保存文稿。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                buttons(confirm: "授权并安装")
            }
        }.padding(26).frame(width: 500)
    }

    private func header(path: String, title: String, badge: String, from: String, to: String) -> some View {
        HStack(spacing: 16) {
            AppIcon(path: path, size: 64)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.shield.fill").font(.title3).foregroundStyle(.white, .green).offset(x: 6, y: 6)
                }
            VStack(alignment: .leading, spacing: 5) {
                StatusBadge(text: badge, symbol: "checkmark.seal.fill", tone: .success)
                Text(title).font(Theme.display(22))
                VersionTransition(from: from, to: to, font: .title3)
            }
        }
    }

    private func checklist(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.self) { item in
                Label { Text(item) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }.font(.callout)
            }
        }.card(padding: 14, tint: .green)
    }

    private func buttons(confirm: String) -> some View {
        HStack {
            Spacer()
            Button("取消") { store.discardInstallation() }.keyboardShortcut(.cancelAction)
            Button(confirm) { store.confirmInstallation() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(.top, 4)
    }
}
