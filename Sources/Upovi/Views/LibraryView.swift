import SwiftUI
import AppKit
import UpoviCore

/// Every scanned application, filterable by check outcome, with a collapsible inspector.
struct LibraryView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            header.entrance(0).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            AppTable(store: store).entrance(1)
        }
        // Leave room for the widest sidebar and inspector in the 1,000-point minimum window.
        // The table owns horizontal scrolling when its columns need more space.
        .frame(minWidth: 300)
        .navigationTitle("全部应用")
        .inspector(isPresented: $store.libraryInspectorPresented) {
            AppDetailView(store: store).inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.libraryInspectorPresented.toggle() } label: {
                    Label(store.libraryInspectorPresented ? "隐藏详情" : "显示详情", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(store.libraryInspectorPresented ? "隐藏应用详情（⌥⌘I）" : "显示应用详情（⌥⌘I）")
                .accessibilityIdentifier("toggle-library-inspector")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(store.apps.count) 个本机应用")
                .font(.callout).foregroundStyle(.secondary)
                .help(String(localized: "\(store.apps.count) 个本机应用 · 来自 /Applications、~/Applications 与自定义目录"))
            // Long localized segments must fit the column before using the segmented control.
            ViewThatFits(in: .horizontal) {
                sourcePicker.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
                sourcePicker.pickerStyle(.menu)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("library-header")
    }

    private var sourcePicker: some View {
        Picker("筛选", selection: $store.sourceFilter) {
            ForEach(SourceFilter.allCases) { filter in
                Text(count(filter).map { "\(filter.title) \($0)" } ?? filter.title).tag(filter)
            }
        }
        .accessibilityIdentifier("library-source-filter")
    }

    private func count(_ filter: SourceFilter) -> Int? {
        switch filter {
        case .all: return nil
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
            rows: store.visibleApps.map { .init(app: $0, status: store.status(for: $0), installedVersion: store.displayedInstalledVersion(for: $0)) },
            selection: $store.selection,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.path)]) },
            toggleIgnored: { store.toggleIgnored($0) }
        )
        .overlay {
            if store.visibleApps.isEmpty && !store.scanning {
                if !store.search.isEmpty { ContentUnavailableView.search(text: store.search) }
                else if store.sourceFilter != .all { ContentUnavailableView("没有符合条件的应用", systemImage: "line.3.horizontal.decrease.circle") }
                else { ContentUnavailableView("还没有扫描到应用", systemImage: "square.grid.2x2", description: Text("点击工具栏中的“刷新并检查”开始扫描。")) }
            }
        }
    }
}
