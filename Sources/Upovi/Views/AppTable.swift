import SwiftUI
import AppKit
import UpoviCore

struct AppTable: View {
    @Bindable var store: AppStore

    var body: some View {
        Table(store.visibleApps, selection: $store.selection) {
            TableColumn("应用") { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).lineLimit(1)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 6)
            }.width(min: 190, ideal: 260)
            TableColumn("当前版本") { app in
                Text(app.version).font(.callout.monospacedDigit()).lineLimit(1).help("Build: \(app.build)")
            }.width(min: 70, ideal: 88, max: 130)
            TableColumn("状态") { app in
                if store.ignored.contains(app.bundleID) {
                    Text("已忽略").foregroundStyle(.secondary)
                } else if let candidate = store.assessment(for: app).sourceUpdates.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.version).font(.callout.monospacedDigit()).foregroundStyle(Color.accentColor)
                        Text("来源有更新").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let lead = store.assessment(for: app).communityLeads.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lead.report.version).font(.callout.monospacedDigit()).foregroundStyle(.orange)
                        Text("社区未核实").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(status(app)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.width(min: 90, ideal: 105, max: 140)
            TableColumn("P2P") { app in
                Toggle("对 \(app.name) 使用 P2P 检测", isOn: Binding(get: { store.selectedBundles.contains(app.bundleID) }, set: { store.setSelected(app, enabled: $0) }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(store.syncing)
                    .help("加入 P2P 检测范围；只有开启共享后才会发布此应用的版本")
            }.width(42)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let app = store.apps.first(where: { $0.id == id }) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                Button(store.ignored.contains(app.bundleID) ? "恢复更新提醒" : "忽略更新提醒") { store.toggleIgnored(app) }
            }
        }
        .overlay {
            if store.visibleApps.isEmpty && !store.scanning {
                ContentUnavailableView(store.section == .updates ? "暂无来源更新" : "没有匹配的应用", systemImage: "checkmark.circle", description: Text("点击“检查更新”，或调整搜索条件。社区报告不代表已确认更新。"))
            }
        }
    }

    private func status(_ app: InstalledApp) -> String {
        if app.isAppStore { return "App Store" }
        guard let result = store.sourceResults[app.id] else { return "尚未检查" }
        switch result.status {
        case .unsupported: return "未适配来源"
        case .partial: return "部分检测失败"
        case .failed: return "检测失败"
        case .current: return "已检查，未发现更新"
        case .updates: return "来源有更新"
        case .appStore: return "App Store"
        }
    }
}
