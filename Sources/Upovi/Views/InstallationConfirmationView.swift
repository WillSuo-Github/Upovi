import SwiftUI

struct InstallationConfirmationView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let update = store.preparedUpdate {
                Label("更新已验证", systemImage: "checkmark.shield.fill").font(.title2.bold()).foregroundStyle(.tint)
                Text(update.application.name).font(.headline)
                Text("\(update.application.version) → \(update.replacement.version)").font(.title3.monospacedDigit())
                Text("下载完整性、应用标识、开发者签名和 macOS 信任检查均已通过。")
                Text("安装会请求关闭应用，并保留旧版本以便恢复。请先保存正在编辑的文稿。")
                    .foregroundStyle(.secondary)
                Toggle("使用管理员权限安装", isOn: $store.administratorInstallRequested)
                if store.administratorInstallRequested { Text("将显示 macOS 管理员授权窗口，并在系统事务目录保留主应用备份。").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("取消") { store.discardInstallation() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("关闭应用并安装") { store.confirmInstallation() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else if let package = store.preparedPackage {
                Label("安装包签名已验证", systemImage: "shippingbox.fill").font(.title2.bold())
                Text(package.plan.application.name).font(.headline)
                Text("\(package.plan.application.version) → \(package.plan.version)").font(.title3)
                Text("已核对下载完整性、安装包开发者和 macOS 信任。授权后将检查安装负载的应用身份，再由 Upovi 执行系统安装工具。")
                Text("PKG 可运行安装脚本并修改系统服务。Upovi 保留主应用备份，但恢复主应用不会撤销安装脚本、驱动或其他系统改动。请先保存文稿。").foregroundStyle(.secondary)
                HStack {
                    Button("取消") { store.discardInstallation() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("授权并安装") { store.confirmInstallation() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 480)
    }
}
