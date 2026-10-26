import SwiftUI

struct ApplicationTableRow: View {
    let row: ApplicationTable.Row
    let widths: [CGFloat]
    let selected: Bool
    let focused: Bool
    let select: () -> Void
    let reveal: () -> Void
    let toggleIgnored: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    AppIcon(path: row.app.path, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.app.name).lineLimit(1)
                        Text(row.app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("\(row.app.name)\n\(row.app.bundleID)")
                .cellWidth(widths[0])
                Text(row.app.version).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).help("Build: \(row.app.build)").cellWidth(widths[1])
                Group {
                    if let version = row.status.targetVersion {
                        ToneText(text: version, tone: row.status.tone).font(.callout.monospacedDigit().weight(.semibold)).lineLimit(1)
                    } else { Text("—").foregroundStyle(.tertiary) }
                }.cellWidth(widths[2])
                StatusBadge(text: row.status.shortLabel, symbol: row.status.symbol, tone: row.status.tone).cellWidth(widths[3])
            }
            .frame(height: ApplicationTable.rowHeight)
            .contentShape(Rectangle())
            .foregroundStyle(selected && focused ? Color.white : Color.primary)
            .environment(\.backgroundProminence, selected && focused ? .increased : .standard)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6).fill(focused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary))
                }
            }
            .overlay(alignment: .bottom) {
                if !selected { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5).padding(.leading, 46).padding(.trailing, 8) }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            Button("在 Finder 中显示", action: reveal)
            Button(row.status == .ignored ? "恢复更新提醒" : "忽略更新提醒", action: toggleIgnored)
        }
        .accessibilityLabel("\(row.app.name), \(row.app.bundleID), 当前版本 \(row.app.version), \(row.status.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("application-row-\(row.app.id)")
    }
}

private extension View {
    func cellWidth(_ width: CGFloat) -> some View {
        padding(.horizontal, 8).frame(width: width, alignment: .leading)
    }
}
