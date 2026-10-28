import SwiftUI

/// One header keeps its position and height when an individual update or batch starts.
struct UpdatesOverview: View {
    let store: AppStore
    let total: Int
    let installable: Int

    private var batch: Bool { store.bulkSummaryVisible }
    private var transfers: [TransferProgress] { Array(store.transfers.values) }
    private var active: Bool { batch || !transfers.isEmpty }
    private var fraction: Double {
        batch ? store.bulkOverallFraction : transfers.isEmpty ? 0 : transfers.reduce(0) { $0 + $1.fraction } / Double(transfers.count)
    }

    private var tone: Tone {
        guard batch, !store.bulkUpdating else { return .accent }
        if store.bulkFailedCount > 0 { return .warning }
        return store.bulkCompletedCount == store.bulkInstallableCount ? .success : .neutral
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.system(size: 16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(subtitle)
                }
                .frame(width: min(200, geometry.size.width * 0.26), alignment: .leading)
                HStack(spacing: 10) {
                    FlowProgressBar(value: fraction, tone: tone,
                                    active: store.bulkUpdating || transfers.contains(where: \.isActive), height: 5)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .opacity(active ? 1 : 0).accessibilityHidden(!active)
                DownloadRate(transfers: transfers, total: true)
                    .frame(width: 112, alignment: .leading)
                    .opacity(active ? 1 : 0).accessibilityHidden(!active)
                UpdatesOverviewActions(store: store, total: total)
            }
            .frame(height: 52)
        }
        .frame(height: 52)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .modifier(UpdatesSurface())
        .accessibilityIdentifier("updates-overview")
    }

    @ViewBuilder private var title: some View {
        if batch {
            if store.bulkUpdating {
                Text(store.bulkStopRequested ? "正在停止…" : "正在更新 \(store.bulkInstallableCount) 个应用")
            } else { Text(store.bulkCompletedCount == store.bulkInstallableCount ? "全部更新完成" : "更新已结束") }
        } else if !transfers.isEmpty { Text("正在更新 \(transfers.count) 个应用") }
        else if total > 0 { Text("\(total) 个应用有来源更新") }
        else if store.scanning { Text("正在扫描本机应用…") }
        else if store.checking { Text("正在检查更新…") }
        else if store.refreshing { Text("正在连接更新来源…") }
        else if store.lastChecked == nil { Text("检查一下有没有新版本") }
        else { Text("没有来源报告的更新") }
    }

    private var subtitle: String {
        if batch {
            var parts = [String(localized: "已完成 \(store.bulkFinishedCount) / \(store.bulkInstallableCount)")]
            if !store.bulkUpdating, store.bulkCompletedCount != store.bulkFinishedCount {
                parts.append(String(localized: "成功 \(store.bulkCompletedCount)"))
            }
            if store.bulkFailedCount > 0 { parts.append(String(localized: "失败 \(store.bulkFailedCount)")) }
            return parts.joined(separator: " · ")
        }
        if let transfer = transfers.first { return transfer.label }
        if total > 0 {
            var parts = [String(localized: "\(installable) 个可由 Upovi 验证并安装")]
            if total > installable { parts.append(String(localized: "\(total - installable) 个需官方渠道")) }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let date = store.lastChecked { parts.append(String(localized: "上次检查 \(date.relativeDescription)")) }
        if store.incompleteCheckCount > 0 { parts.append(String(localized: "\(store.incompleteCheckCount) 个应用未能完整检查")) }
        if store.lastChecked != nil { parts.append(String(localized: "结果为空并不代表所有应用都已是最新")) }
        else { parts.append(String(localized: "Upovi 会扫描 /Applications 与 ~/Applications，再向 Sparkle、Homebrew、GitHub 与 App Store 来源核对版本。")) }
        return parts.joined(separator: " · ")
    }
}

/// Keep header actions on the same line as the title and transfer rate.
private struct UpdatesOverviewActions: View {
    let store: AppStore
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            if store.bulkSummaryVisible {
                if store.bulkUpdating {
                    Button(store.bulkStopRequested ? "正在停止…" : "停止更新") { store.stopAllUpdates() }
                        .disabled(store.bulkStopRequested)
                        .help(store.bulkStopRequested ? "正在安装的应用完成后停止" : "停止更新")
                } else {
                    if let record = store.batchHistory.first(where: { $0.id == store.bulkRecordID }), !record.retryIDs.isEmpty {
                        Button("重试未完成项") { store.retryBatch(record) }
                    }
                    Button("完成") { store.dismissBulkSummary() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else if !store.transfers.isEmpty {
                Button("取消下载") { store.cancelInstallation() }
                    .disabled(!store.transfers.values.contains(where: \.canCancel))
            } else {
                if total > 0 {
                    Button("全部更新…") { store.reviewAllUpdates() }
                        .buttonStyle(.borderedProminent).disabled(store.operationBusy)
                        .help("下载并安装所有可验证的来源更新；需官方更新的应用将单独列出")
                        .accessibilityIdentifier("update-all-apps")
                }
                if total == 0, store.incompleteCheckCount > 0 {
                    Button("查看检测异常") { store.section = .all; store.sourceFilter = .incomplete }
                }
                Button { store.refreshAll() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly).help("重新检查").disabled(store.operationBusy)
            }
        }
        .controlSize(.regular).fixedSize()
    }
}
