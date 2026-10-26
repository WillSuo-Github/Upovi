import SwiftUI
import UpoviCore

struct BulkUpdateView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.bulkHasRun ? "全部更新进度" : "更新全部应用").font(.title2.bold())
            if store.bulkHasRun {
                Text("已完成 \(store.bulkCompletedCount) 个 · 失败 \(store.bulkFailedCount) 个 · 共 \(store.bulkItems.count) 个来源更新")
                if store.bulkUpdating {
                    ProgressView(value: Double(store.bulkOutcomes.count), total: Double(max(1, store.bulkItems.count)))
                    Text(store.installationProgress).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("可自动更新 \(store.bulkInstallableCount) 个，需官方处理 \(store.bulkItems.count - store.bulkInstallableCount) 个。使用全部应用的检测结果，不受搜索和列表筛选影响；已忽略、跳过或稍后提醒的更新不参与。")
                Text("更新时会请求退出应用，请先保存文稿。旧版主应用将保留以便恢复；需要管理员权限时会出现系统授权窗口。")
                    .foregroundStyle(.secondary)
                if store.bulkItems.contains(where: { $0.canInstall && $0.candidate.download?.url.pathExtension.lowercased() == "pkg" }) {
                    Text("清单包含 PKG 安装包，可运行脚本并修改系统。恢复主应用不能撤销脚本或系统改动。")
                        .foregroundStyle(.secondary)
                }
            }
            List(store.bulkItems) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(for: item)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.application.name).font(.headline)
                        Text(item.application.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Text("\(item.application.version) → \(item.candidate.version)").font(.callout.monospacedDigit())
                        Text(status(for: item)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if !item.canInstall {
                        if item.application.isAppStore {
                            Button("App Store") { store.open(URL(string: "macappstore://showUpdatesPage")) }
                        } else if item.application.bundleID == "app.upovi.Upovi" {
                            Button("自身更新") { store.bulkUpdatePresented = false; SelfUpdateService.shared.check() }.disabled(store.bulkUpdating)
                        } else if let url = item.candidate.url {
                            Button("官方来源") { store.open(url) }
                        }
                    }
                }.padding(.vertical, 6)
            }.frame(minHeight: 180)
            HStack {
                if store.bulkUpdating {
                    Button(store.bulkStopRequested ? "正在停止…" : "停止后续更新") { store.stopAllUpdates() }
                        .disabled(store.bulkStopRequested)
                    if store.bulkStopRequested && !store.canCancelInstallation {
                        Text("当前安装结束后停止").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button(store.bulkHasRun ? "完成" : "取消") { store.bulkUpdatePresented = false }.keyboardShortcut(.cancelAction)
                    if store.bulkHasRun, let record = store.batchHistory.first(where: { $0.id == store.bulkRecordID }), !record.retryIDs.isEmpty {
                        Button("重新检测并重试未完成项") { store.retryBatch(record) }
                    }
                }
                Spacer()
                if !store.bulkHasRun {
                    Button("开始更新 \(store.bulkInstallableCount) 个应用") { store.startAllUpdates() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(store.bulkInstallableCount == 0 || !store.networkAvailable)
                        .accessibilityIdentifier("bulk-update-start")
                }
            }
        }.padding(24).frame(width: 620, height: 540)
        .interactiveDismissDisabled(store.bulkUpdating)
    }

    private func status(for item: BulkUpdateItem) -> String {
        if let outcome = store.bulkOutcomes[item.id] { return outcome.detail }
        if store.bulkUpdating && store.bulkCurrentID == item.id { return "正在处理" }
        return item.manualReason ?? "等待下载与验证"
    }

    private func symbol(for item: BulkUpdateItem) -> String {
        if let outcome = store.bulkOutcomes[item.id] {
            switch outcome.status {
            case .installed: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle"
            case .cancelled: return "minus.circle"
            case .manual: return "arrow.up.forward.app"
            }
        }
        return item.canInstall ? "arrow.down.circle" : "arrow.up.forward.app"
    }
}
