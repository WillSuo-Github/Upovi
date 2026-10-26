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
        ApplicationTable(
            rows: store.visibleApps.map { .init(app: $0, status: store.status(for: $0)) },
            selection: $store.selection,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.path)]) },
            toggleIgnored: { store.toggleIgnored($0) }
        )
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
