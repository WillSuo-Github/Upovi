import SwiftUI
import AppKit
import UpoviCore

struct BatchHistoryView: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量任务记录").font(.headline)
            if store.batchHistory.isEmpty { Text("尚无批量任务").foregroundStyle(.secondary) }
            ForEach(store.batchHistory) { record in
                DisclosureGroup {
                    ForEach(record.entries, id: \.item.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.item.application.name + " → " + entry.item.candidate.version)
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                    if !record.retryIDs.isEmpty {
                        Button("重新检测并恢复未完成项") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); store.retryBatch(record) }
                            .disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                    }
                } label: {
                    Text("\(record.startedAt.formatted()) · 完成 \(record.entries.filter { $0.phase == .installed || $0.phase == .current }.count)/\(record.entries.count) · \(record.finishedAt == nil ? "未完成" : "已结束")")
                        .font(.callout)
                }
            }
        }
    }
}
