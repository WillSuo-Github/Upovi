import AppKit
import SwiftUI
import UpoviCore

/// Own the native table so its complete document height is known before any row is visited.
/// SwiftUI still owns the inventory, status, selection and cell presentation.
struct ApplicationTable: NSViewRepresentable {
    struct Row: Equatable {
        let app: InstalledApp
        let status: AppStatus
    }

    let rows: [Row]
    @Binding var selection: String?
    let reveal: (InstalledApp) -> Void
    let toggleIgnored: (InstalledApp) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.rowSizeStyle = .custom
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = false
        table.setAccessibilityIdentifier("application-table")
        table.setAccessibilityLabel("全部应用")
        for column in Column.allCases {
            let native = NSTableColumn(identifier: column.identifier)
            native.title = column.title
            native.minWidth = column.minimumWidth
            native.resizingMask = [.autoresizingMask, .userResizingMask]
            native.width = column == .application ? 280 : 120
            native.maxWidth = column == .application ? .greatestFiniteMagnitude : column == .status ? 180 : 160
            table.addTableColumn(native)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    enum Column: String, CaseIterable {
        case application, current, available, status
        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
        var title: String {
            switch self {
            case .application: "应用"
            case .current: "当前版本"
            case .available: "可用版本"
            case .status: "状态"
            }
        }
        var minimumWidth: CGFloat { self == .application ? 200 : self == .status ? 100 : 80 }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private var parent: ApplicationTable
        private var rows: [Row] = []
        private var updating = false
        weak var table: NSTableView?

        init(_ parent: ApplicationTable) { self.parent = parent }

        func update(_ parent: ApplicationTable) {
            self.parent = parent
            guard let table else { return }
            updating = true
            defer { updating = false }
            if rows != parent.rows {
                let sameIdentity = rows.map(\.app.id) == parent.rows.map(\.app.id)
                let oldRows = rows
                let topRow = table.row(at: table.visibleRect.origin)
                let anchor = oldRows.indices.contains(topRow) ? oldRows[topRow].app.id : nil
                let offset = topRow >= 0 ? table.visibleRect.minY - table.rect(ofRow: topRow).minY : 0
                rows = parent.rows
                if sameIdentity {
                    let changed = IndexSet(rows.indices.filter { rows[$0] != oldRows[$0] })
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                } else {
                    table.reloadData()
                    if let anchor, let index = rows.firstIndex(where: { $0.app.id == anchor }),
                       let scroll = table.enclosingScrollView {
                        let maximum = max(0, table.frame.height - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                            y: min(maximum, max(0, table.rect(ofRow: index).minY + offset))))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
            }
            let index = rows.firstIndex { $0.app.id == parent.selection }
            let selected = index.map { IndexSet(integer: $0) } ?? []
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let id = tableColumn?.identifier,
                  let column = Column(rawValue: id.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ApplicationTableCell ?? ApplicationTableCell()
            cell.identifier = id
            cell.configure(row: rows[row], column: column)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let id = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].app.id : nil
            if parent.selection != id { parent.selection = id }
            table.window?.makeFirstResponder(table)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard rows.indices.contains(index) else { return }
            let row = rows[index]
            for (title, action) in [("在 Finder 中显示", #selector(reveal(_:))),
                                    (row.status == .ignored ? "恢复更新提醒" : "忽略更新提醒", #selector(toggleIgnored(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = row.app.id
                menu.addItem(item)
            }
        }

        private func app(for item: NSMenuItem) -> InstalledApp? {
            rows.first { $0.app.id == item.representedObject as? String }?.app
        }
        @objc private func reveal(_ item: NSMenuItem) { if let app = app(for: item) { parent.reveal(app) } }
        @objc private func toggleIgnored(_ item: NSMenuItem) { if let app = app(for: item) { parent.toggleIgnored(app) } }
    }
}

/// Cell hosting never participates in table sizing; AppKit lays out the reusable fixed-height rows.
private final class ApplicationTableCell: NSTableCellView {
    private var row: ApplicationTable.Row?
    private var column: ApplicationTable.Column = .application
    private let host = NSHostingView<TableCellContent?>(rootView: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // All cell content is read-only. Let the native table receive clicks and become
    // first responder instead of the embedded hosting view consuming mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refresh() }
    }

    func configure(row: ApplicationTable.Row, column: ApplicationTable.Column) {
        self.row = row
        self.column = column
        refresh()
        toolTip = column == .current ? "Build: \(row.app.build)" : column == .application ? "\(row.app.name)\n\(row.app.bundleID)" : nil
        setAccessibilityLabel(column == .application ? "\(row.app.name), \(row.app.bundleID)"
                              : column == .current ? row.app.version
                              : column == .available ? row.status.targetVersion ?? "无可用版本" : row.status.label)
    }

    private func refresh() {
        guard let row else { return }
        host.rootView = TableCellContent(row: row, column: column, emphasized: backgroundStyle == .emphasized)
    }
}

private struct TableCellContent: View {
    let row: ApplicationTable.Row
    let column: ApplicationTable.Column
    let emphasized: Bool

    var body: some View {
        content
            .font(.body)
            .foregroundStyle(emphasized ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)
    }

    @ViewBuilder private var content: some View {
        switch column {
        case .application:
            HStack(spacing: 10) {
                AppIcon(path: row.app.path, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.app.name).lineLimit(1)
                    Text(row.app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .current:
            Text(row.app.version).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).help("Build: \(row.app.build)")
        case .available:
            if let version = row.status.targetVersion {
                ToneText(text: version, tone: row.status.tone).font(.callout.monospacedDigit().weight(.semibold)).lineLimit(1)
            } else { Text("—").foregroundStyle(.tertiary) }
        case .status:
            StatusBadge(text: row.status.shortLabel, symbol: row.status.symbol, tone: row.status.tone)
        }
    }
}
