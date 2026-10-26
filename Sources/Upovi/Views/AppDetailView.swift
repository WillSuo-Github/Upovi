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
                        detail("安装位置", app.path)
                    }
                    let assessment = store.fullAssessment(for: app)
                    if app.isAppStore, assessment.sourceUpdates.isEmpty, let id = store.sourceResults[app.id]?.appStoreID {
                        Button("检查并更新此应用") {
                            store.reviewStoreUpdate(app, candidate: .init(version: app.version, source: "App Store", isCommunity: false, url: nil, appStoreID: id))
                        }.disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                            .accessibilityIdentifier("check-update-store-application")
                    }
                    if !assessment.sourceUpdates.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("来源更新").font(.headline)
                            ForEach(Array(assessment.sourceUpdates.enumerated()), id: \.offset) { _, candidate in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("来源提供 \(candidate.version)", systemImage: "arrow.down.circle")
                                        .font(.headline).foregroundStyle(Color.accentColor)
                                    Text(candidate.source).font(.caption).foregroundStyle(.secondary)
                                    if let notes = candidate.releaseNotes, !notes.isEmpty {
                                        DisclosureGroup("更新说明") { Text(notes).font(.caption).textSelection(.enabled) }
                                    }
                                    if candidate.url != nil { Button("查看更新来源") { store.open(candidate.url) } }
                                    let skipped = store.updatePolicy.skipped.contains(UpdatePolicy.key(candidate, app: app))
                                    Button(skipped ? "恢复此版本提醒" : "跳过此版本") { store.setSkipped(candidate, app: app, skipped: !skipped) }
                                    Menu("稍后提醒") {
                                        Button("1 小时后") { store.deferUpdates(for: app, until: Date().addingTimeInterval(3600)) }
                                        Button("明天") { store.deferUpdates(for: app, until: Date().addingTimeInterval(86400)) }
                                        Button("一周后") { store.deferUpdates(for: app, until: Date().addingTimeInterval(604800)) }
                                        Button("取消稍后提醒") { store.deferUpdates(for: app, until: nil) }
                                    }.help("到期后，在下一次来源检查时恢复提醒；需要应用正在运行且通知已启用。")
                                    if app.isAppStore, candidate.appStoreID != nil {
                                        Button("在 Upovi 中更新") { store.reviewStoreUpdate(app, candidate: candidate) }
                                            .buttonStyle(.borderedProminent).disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                                            .accessibilityIdentifier("update-store-application")
                                    } else if candidate.download?.hasIntegrityProof == true, app.teamID != nil, app.bundleID != "app.upovi.Upovi" {
                                        Button("下载并验证更新") { store.prepareInstallation(candidate, app: app) }
                                            .buttonStyle(.borderedProminent).disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                                    } else {
                                        Text("此更新请使用官方来源或应用内更新。").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    if !assessment.communityLeads.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("社区版本线索").font(.headline)
                            ForEach(assessment.communityLeads) { CommunityLeadView(lead: $0) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("检测来源").font(.headline)
                        Text(store.sourceResults[app.id]?.note ?? "尚未检查开发者更新源").font(.caption).foregroundStyle(.secondary)
                        if let url = store.sourceResults[app.id]?.manualURL { Button("打开官方更新入口") { store.open(url) } }
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
