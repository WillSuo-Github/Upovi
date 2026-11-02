import SwiftUI
import UpoviCore

/// A global binary is a peer of a desktop app in the same updates list.
struct ToolUpdateRow: View {
    let store: AppStore
    let item: ToolUpdateItem
    var confirmation = false

    private var record: ToolUpdateRecord? { store.bulkSummaryVisible ? store.toolOutcomes[item.id] : nil }
    private var isBatch: Bool { store.bulkSummaryVisible && store.toolBatchItems.contains { $0.id == item.id } }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal.fill").font(.system(size: confirmation ? 24 : 30))
                .foregroundStyle(Theme.accent).frame(width: confirmation ? 32 : 44, height: confirmation ? 32 : 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.package.name).font(.system(size: confirmation ? 13 : 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    VersionTransition(from: item.package.installed, to: item.package.available, font: .system(size: 12))
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(item.source.title).foregroundStyle(.secondary).lineLimit(1)
                }.font(.system(size: 12))
                if let record, record.state != .succeeded {
                    Text(record.detail).font(.system(size: 12)).foregroundStyle(record.state == .failed ? Color.orange : Color.secondary)
                        .lineLimit(3).help(record.detail)
                } else if store.toolRunningID == item.id {
                    Text("正在更新并核对版本…").font(.caption).foregroundStyle(.secondary)
                } else if isBatch && store.bulkUpdating {
                    Text("排队中").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !confirmation {
                Group {
                    if store.toolRunningID == item.id { ProgressView().controlSize(.small) }
                    else if let record {
                        Image(systemName: record.state == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(record.state == .succeeded ? Color.green : Color.orange)
                    } else if isBatch { Image(systemName: "clock").foregroundStyle(.secondary) }
                    else {
                        Button("更新") { store.reviewToolUpdates([item]) }
                            .buttonStyle(PillButtonStyle()).disabled(store.operationBusy)
                            .accessibilityIdentifier("update-tool-" + item.id)
                    }
                }.frame(minWidth: 64, minHeight: 52)
                // Align the update action with app rows, reserving their trailing menu slot.
                Color.clear.frame(width: 26, height: 26).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, confirmation ? 10 : 12)
        .accessibilityIdentifier("tool-update-row-" + item.id)
    }
}
