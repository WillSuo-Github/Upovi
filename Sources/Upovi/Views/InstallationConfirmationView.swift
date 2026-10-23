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
                HStack {
                    Button("取消") { store.discardInstallation() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("关闭应用并安装") { store.confirmInstallation() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 480)
    }
}
