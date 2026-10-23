import SwiftUI
import UpoviCore

struct SourceEditorView: View {
    @Bindable var store: AppStore
    let app: InstalledApp
    @Environment(\.dismiss) private var dismiss
    @State private var feed = ""
    @State private var repository = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(app.name) 的更新来源").font(.title2.bold())
            Text("可补充开发者提供的 appcast，或该应用的官方 GitHub 仓库。留空恢复自动检测。")
                .foregroundStyle(.secondary)
            TextField("HTTPS appcast URL", text: $feed)
            TextField("GitHub owner/repository", text: $repository)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存来源") {
                    do { try store.configureSource(for: app, feed: feed, repository: repository); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 560)
            .onAppear {
                feed = store.sourceOverrides[app.bundleID]?.appcast?.absoluteString ?? ""
                repository = store.sourceOverrides[app.bundleID]?.githubRepository ?? ""
            }
    }
}
