import SwiftUI
import UpoviCore

/// Fixed-height, eagerly laid-out rows keep the complete scroll extent deterministic.
struct ApplicationTable: View {
    struct Row: Equatable {
        let app: InstalledApp
        let status: AppStatus
    }

    static let rowHeight: CGFloat = 46
    let rows: [Row]
    @Binding var selection: String?
    let reveal: (InstalledApp) -> Void
    let toggleIgnored: (InstalledApp) -> Void
    @State private var columns = ApplicationTableColumns()
    @State private var dragStart: ApplicationTableColumns?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = columns.fitted(to: geometry.size.width - 32)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header(layout: layout)
                    Divider()
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            // Do not use lazy rows here: their estimated heights can change the scroll extent.
                            VStack(spacing: 0) {
                                ForEach(rows, id: \.app.id) { row in
                                    ApplicationTableRow(row: row, widths: layout.widths,
                                        selected: selection == row.app.id, focused: focused,
                                        select: { selection = row.app.id; focused = true },
                                        reveal: { reveal(row.app) }, toggleIgnored: { toggleIgnored(row.app) })
                                        .id(row.app.id)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("application-table-scroll")
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focused)
                        .onMoveCommand { direction in
                            guard direction == .up || direction == .down else { return }
                            move(by: direction == .up ? -1 : 1, reader: reader)
                        }
                        .onKeyPress(keys: [.home, .end, .pageUp, .pageDown]) { key in
                            guard !rows.isEmpty else { return .ignored }
                            let page = max(1, Int((geometry.size.height - 29) / Self.rowHeight))
                            switch key.key {
                            case .home: select(index: 0, reader: reader)
                            case .end: select(index: rows.count - 1, reader: reader)
                            case .pageUp: move(by: -page, reader: reader)
                            default: move(by: page, reader: reader)
                            }
                            return .handled
                        }
                        .onChange(of: rows.map(\.app.id)) { _, ids in
                            if let selection, !ids.contains(selection) { self.selection = ids.first }
                        }
                    }
                }
                .frame(width: layout.totalWidth, height: geometry.size.height)
                .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("全部应用")
        .accessibilityIdentifier("application-table")
    }

    private func header(layout: ApplicationTableColumns) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { index in
                Text(["应用", "当前版本", "可用版本", "状态"][index])
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(width: layout.widths[index], height: 28, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if index < 3 { resizeHandle(index: index, layout: layout) }
                    }
            }
        }
    }

    private func resizeHandle(index: Int, layout: ApplicationTableColumns) -> some View {
        Rectangle().fill(.separator).frame(width: 1, height: 12)
            .frame(width: 10, height: 28).contentShape(Rectangle())
            .help("拖动调整列宽")
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = layout }
                    columns = (dragStart ?? layout).resizingBoundary(index, by: value.translation.width)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel(String(localized: "调整“\([String(localized: "应用"), String(localized: "当前版本"), String(localized: "可用版本")][index])”列宽"))
            .accessibilityValue("\(Int(layout.widths[index]))")
            .accessibilityAdjustableAction { direction in
                columns = layout.resizingBoundary(index, by: direction == .increment ? 10 : -10)
            }
    }

    private func move(by offset: Int, reader: ScrollViewProxy) {
        let current = rows.firstIndex { $0.app.id == selection }
        let next = current.map { $0 + offset } ?? (offset < 0 ? rows.count - 1 : 0)
        select(index: next, reader: reader)
    }

    private func select(index: Int, reader: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let id = rows[min(rows.count - 1, max(0, index))].app.id
        selection = id
        reader.scrollTo(id)
    }
}
