import SwiftUI
import UpoviCore

struct BulkUpdateView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.bulkHasRun ? "更新进度" : "确认更新应用").font(.title2.bold())
            if store.bulkHasRun {
                Text("已完成 \(store.bulkCompletedCount) 个 · 失败 \(store.bulkFailedCount) 个 · 共 \(store.bulkItems.count) 个更新任务")
                if store.bulkUpdating {
                    ProgressView(value: Double(store.bulkOutcomes.count), total: Double(max(1, store.bulkItems.count)))
                    Text(store.installationProgress).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("可自动更新 \(store.bulkInstallableCount) 个，需官方处理 \(store.bulkItems.count - store.bulkInstallableCount) 个。使用全部应用的检测结果，不受搜索和列表筛选影响；已忽略、跳过或稍后提醒的更新不参与。")
                Text("更新时会请求退出应用，请先保存文稿。直接下载更新会保留旧版主应用；需要管理员权限时会出现系统授权窗口。")
                    .foregroundStyle(.secondary)
                if store.bulkItems.contains(where: { $0.canInstall && $0.application.isAppStore }) {
                    Text("商店应用由 Upovi 发起 Apple 服务更新，可能要求 Apple 账户认证。不提供 Upovi 旧版备份或下载暂停；停止只影响后续任务，已交给商店的更新可能继续。")
                        .foregroundStyle(.secondary)
                }
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
                        if item.application.isAppStore && !item.canInstall {
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
        return item.manualReason ?? (item.application.isAppStore ? "将检查并更新可用的商店版本" : "等待下载与验证")
    }

    private func symbol(for item: BulkUpdateItem) -> String {
        if let outcome = store.bulkOutcomes[item.id] {
            switch outcome.status {
            case .installed, .current: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle"
            case .cancelled: return "minus.circle"
            case .manual: return "arrow.up.forward.app"
            }
        }
        return item.canInstall ? "arrow.down.circle" : "arrow.up.forward.app"
    }
}
