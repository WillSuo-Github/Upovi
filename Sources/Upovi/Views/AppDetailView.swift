import SwiftUI
import AppKit
import UpoviCore

struct AppDetailView: View {
    @Bindable var store: AppStore
    @State private var sourceEditor = false

    var body: some View {
        ScrollView {
            if let app = store.selectedApp {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 64, height: 64)
                        Text(app.name).font(.title2.bold()).textSelection(.enabled)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        detail("当前版本", app.version)
                        detail("构建号", app.build.isEmpty ? "未知" : app.build)
                        detail("分发渠道", app.isAppStore ? "App Store" : "开发者分发")
                        detail("Team ID", app.teamID ?? "未识别")
                    }
                    if app.isAppStore {
                        Button("打开 App Store 更新") { store.open(URL(string: "macappstore://showUpdatesPage")) }
                    }
                    let candidates = store.candidates(for: app)
                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("更新与线索").font(.headline)
                            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(candidate.isCommunity ? "社区发现 \(candidate.version)" : "来源提供 \(candidate.version)", systemImage: candidate.isCommunity ? "person.2" : "arrow.down.circle")
                                        .font(.headline).foregroundStyle(candidate.isCommunity ? Color.orange : Color.accentColor)
                                    Text(candidate.source).font(.caption).foregroundStyle(.secondary)
                                    if candidate.isCommunity {
                                        Text("节点签名证明记录来源，不代表开发者认可。请到官方渠道核实，Upovi 不使用 P2P 分发安装包。")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(candidate.observedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        if candidate.url != nil { Button("查看更新来源") { store.open(candidate.url) } }
                                        if candidate.download?.hasIntegrityProof == true, app.teamID != nil, app.bundleID != "app.upovi.Upovi" {
                                            Button("下载并验证更新") { store.prepareInstallation(candidate, app: app) }
                                                .buttonStyle(.borderedProminent).disabled(store.installing || store.checking || store.scanning)
                                        } else {
                                            Text("此更新请使用官方来源或应用内更新。").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("检测来源").font(.headline)
                        Text(store.sourceResults[app.id]?.note ?? "尚未检查开发者更新源").font(.caption).foregroundStyle(.secondary)
                        if let feed = app.feedURL { Text(feed.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Button("设置更新来源…") { sourceEditor = true }
                        .sheet(isPresented: $sourceEditor) { SourceEditorView(store: store, app: app) }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                    Button(store.ignored.contains(app.bundleID) ? "恢复更新提醒" : "忽略更新提醒") { store.toggleIgnored(app) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("选择一个应用", systemImage: "app.dashed")
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
}
