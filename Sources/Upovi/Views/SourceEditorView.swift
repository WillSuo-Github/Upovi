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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIcon(path: app.path, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(app.name) 的更新来源").font(.title3.weight(.semibold))
                    Text("补充开发者提供的 appcast，或该应用的官方 GitHub 仓库。两项都留空即恢复自动检测。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                TextField("Sparkle appcast", text: $feed, prompt: Text("https://example.com/appcast.xml"))
                TextField("GitHub 仓库", text: $repository, prompt: Text("owner/repository"))
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 110).padding(.horizontal, -20)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存来源") {
                    do { try store.configureSource(for: app, feed: feed, repository: repository); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear {
            feed = store.sourceOverrides[app.bundleID]?.appcast?.absoluteString ?? ""
            repository = store.sourceOverrides[app.bundleID]?.githubRepository ?? ""
        }
    }
}
