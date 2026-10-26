import SwiftUI
import AppKit
import UpoviCore

/// Every scanned application, filterable by check outcome, with an inspector.
struct LibraryView: View {
    @Bindable var store: AppStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
                AppTable(store: store)
            }.frame(minWidth: 460)
            AppDetailView(store: store).frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        }
        .navigationTitle("全部应用")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "全部应用", subtitle: "\(store.apps.count) 个本机应用 · 来自 /Applications、~/Applications 与自定义目录") {
                Text(store.visibleApps.count.formatted()).font(Theme.display(26, weight: .semibold)).monospacedDigit().foregroundStyle(.tertiary)
            }
            Picker("筛选", selection: $store.sourceFilter) {
                ForEach(SourceFilter.allCases) { filter in
                    Text(count(filter).map { "\(filter.rawValue) \($0)" } ?? filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private func count(_ filter: SourceFilter) -> Int? {
        switch filter {
        case .all: return nil
        case .ignored: return store.ignored.isEmpty ? nil : store.apps.filter { store.ignored.contains($0.bundleID) }.count
        default:
            let value = store.apps.filter { filter.includes(store.sourceResults[$0.id]?.status, isAppStore: $0.isAppStore) }.count
            return value == 0 ? nil : value
        }
    }
}

struct AppTable: View {
    @Bindable var store: AppStore

    var body: some View {
        Table(store.visibleApps, selection: $store.selection) {
            TableColumn("应用") { app in
                HStack(spacing: 10) {
                    AppIcon(path: app.path, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 4)
            }.width(min: 200, ideal: 280)
            TableColumn("当前版本") { app in
                Text(app.version).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).help("Build: \(app.build)")
            }.width(min: 80, ideal: 120, max: 160)
            TableColumn("可用版本") { app in
                let status = store.status(for: app)
                if let version = status.targetVersion {
                    ToneText(text: version, tone: status.tone).font(.callout.monospacedDigit().weight(.semibold)).lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }.width(min: 80, ideal: 120, max: 160)
            TableColumn("状态") { app in
                let status = store.status(for: app)
                StatusBadge(text: status.shortLabel, symbol: status.symbol, tone: status.tone)
            }.width(min: 100, ideal: 120, max: 180)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let app = store.apps.first(where: { $0.id == id }) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                Button(store.ignored.contains(app.bundleID) ? "恢复更新提醒" : "忽略更新提醒") { store.toggleIgnored(app) }
            }
        }
        .overlay {
            if store.visibleApps.isEmpty && !store.scanning {
                if !store.search.isEmpty { ContentUnavailableView.search(text: store.search) }
                else if store.sourceFilter == .ignored { ContentUnavailableView("没有已忽略的应用", systemImage: "eye.slash", description: Text("在应用的右键菜单或详情中可以忽略更新提醒。")) }
                else if store.sourceFilter != .all { ContentUnavailableView("没有符合条件的应用", systemImage: "line.3.horizontal.decrease.circle") }
                else { ContentUnavailableView("还没有扫描到应用", systemImage: "square.grid.2x2", description: Text("点击工具栏中的“刷新并检查”开始扫描。")) }
            }
        }
    }
}
