import SwiftUI
import UpoviCore

struct BulkUpdateView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            List {
                let installable = store.bulkItems.filter(\.canInstall), manual = store.bulkItems.filter { !$0.canInstall }
                if !installable.isEmpty {
                    Section(store.bulkHasRun ? "更新任务" : "将由 Upovi 下载、验证并安装") { ForEach(installable) { row($0) } }
                }
                if !manual.isEmpty {
                    Section("需要你通过官方渠道处理") { ForEach(manual) { row($0) } }
                }
            }
            .listStyle(.inset)
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 660, height: 600)
        .interactiveDismissDisabled(store.bulkUpdating)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: store.bulkHasRun ? (store.bulkUpdating ? "arrow.down.circle.dotted" : "checkmark.circle.fill") : "square.and.arrow.down.on.square.fill")
                    .font(.title.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .symbolEffect(.pulse, isActive: store.bulkUpdating)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.bulkHasRun ? (store.bulkUpdating ? "正在更新…" : "更新已结束") : "确认更新应用").font(Theme.display(22))
                    if store.bulkHasRun {
                        Text("已完成 \(store.bulkCompletedCount) 个 · 失败 \(store.bulkFailedCount) 个 · 共 \(store.bulkItems.count) 个").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("可自动更新 \(store.bulkInstallableCount) 个 · 需官方处理 \(store.bulkItems.count - store.bulkInstallableCount) 个").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if store.bulkUpdating {
                VStack(alignment: .leading, spacing: 6) {
                    FlowProgressBar(value: store.bulkOverallFraction, height: 8)
                }
            } else if !store.bulkHasRun {
                VStack(alignment: .leading, spacing: 6) {
                    note("doc.badge.clock", "更新时会请求退出应用，请先保存文稿。直接下载的更新会保留旧版主应用；需要管理员权限时会出现系统授权窗口。")
                    if store.bulkItems.contains(where: { $0.canInstall && $0.application.isAppStore }) {
                        note("bag", "商店应用由 Upovi 发起 Apple 服务更新，可能要求 Apple 账户认证。不提供 Upovi 旧版备份或下载暂停；停止只影响后续任务，已交给商店的更新可能继续。")
                    }
                    if store.bulkItems.contains(where: { $0.canInstall && $0.candidate.download?.url.pathExtension.lowercased() == "pkg" }) {
                        note("exclamationmark.triangle", "清单包含 PKG 安装包，可运行脚本并修改系统。恢复主应用不能撤销脚本或系统改动。", tone: .warning)
                    }
                    Text("使用全部应用的检测结果，不受搜索和列表筛选影响；已忽略、跳过或稍后提醒的更新不参与。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func note(_ symbol: String, _ text: String, tone: Tone = .neutral) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(tone == .neutral ? Theme.accent : tone.color) }
            .font(.callout).foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
    }

    // MARK: Rows

    private func row(_ item: BulkUpdateItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppIcon(path: item.application.path, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.application.name).font(.headline)
                    VersionTransition(from: item.application.version, to: item.candidate.version, font: .caption)
                }
                Text(status(for: item)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            .help(item.application.path)
            Spacer()
            if !item.canInstall {
                if item.application.isAppStore {
                    Button("App Store") { store.open(URL(string: "macappstore://showUpdatesPage")) }
                } else if item.application.bundleID == "app.upovi.Upovi" {
                    Button("自身更新") { store.bulkUpdatePresented = false; SelfUpdateService.shared.check() }.disabled(store.bulkUpdating)
                } else if let url = item.candidate.url {
                    Button("官方来源") { store.open(url) }
                }
            } else {
                let (symbol, tone) = indicator(for: item)
                Image(systemName: symbol).foregroundStyle(tone.color).font(.title3)
                    .symbolEffect(.pulse, isActive: store.bulkActiveIDs.contains(item.id) && store.bulkUpdating)
            }
        }
        .controlSize(.small)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if store.bulkUpdating {
                Button(store.bulkStopRequested ? "正在停止…" : "停止后续更新") { store.stopAllUpdates() }
                    .disabled(store.bulkStopRequested)
                if store.bulkStopRequested {
                    Text("正在安装的应用完成后停止").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(store.bulkHasRun ? "完成" : "取消") { store.bulkUpdatePresented = false }.keyboardShortcut(.cancelAction)
                if store.bulkHasRun, let record = store.batchHistory.first(where: { $0.id == store.bulkRecordID }), !record.retryIDs.isEmpty {
                    Button("重新检测并重试未完成项") { store.retryBatch(record) }
                }
            }
            Spacer()
            if !store.bulkHasRun {
                if !store.networkAvailable { Text("当前没有网络").font(.caption).foregroundStyle(.orange) }
                Button("开始更新 \(store.bulkInstallableCount) 个应用") { store.startAllUpdates() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.bulkInstallableCount == 0 || !store.networkAvailable)
                    .accessibilityIdentifier("bulk-update-start")
            }
        }
    }

    private func status(for item: BulkUpdateItem) -> String {
        if let outcome = store.bulkOutcomes[item.id] { return outcome.detail }
        if store.bulkUpdating, let transfer = store.transfers[item.id], transfer.isActive { return transfer.label }
        return item.manualReason ?? (item.application.isAppStore ? "将检查并更新可用的商店版本" : "等待下载与验证")
    }

    private func indicator(for item: BulkUpdateItem) -> (String, Tone) {
        if let outcome = store.bulkOutcomes[item.id] {
            switch outcome.status {
            case .installed, .current: return ("checkmark.circle.fill", .success)
            case .failed: return ("exclamationmark.triangle.fill", .danger)
            case .cancelled: return ("minus.circle", .neutral)
            case .manual: return ("arrow.up.forward.app", .neutral)
            }
        }
        if store.bulkUpdating && store.bulkActiveIDs.contains(item.id) { return ("arrow.down.circle.fill", .accent) }
        return ("circle.dashed", .neutral)
    }
}
