import SwiftUI
import AppKit
import UpoviCore

/// Confirmation sheet for "Update All". Progress itself lives on the Updates page rows,
/// so before a run this only lists what will happen; after a run it shows each outcome.
struct BulkUpdateView: View {
    @Bindable var store: AppStore

    var body: some View {
        let installable = store.bulkItems.filter(\.canInstall)
        let manual = store.bulkItems.filter { !$0.canInstall }
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !store.bulkHasRun, !notes.isEmpty { notesPanel }
                    if !installable.isEmpty {
                        section(store.bulkHasRun ? String(localized: "更新任务") : String(localized: "将由 Upovi 下载、验证并安装"),
                                items: installable)
                    }
                    if !manual.isEmpty {
                        section(String(localized: "需要你通过官方渠道处理"), items: manual)
                    }
                    if !store.bulkHasRun {
                        Text("使用全部应用的检测结果，不受搜索和列表筛选影响；已忽略、跳过或稍后提醒的更新不参与。")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 600, height: 580)
        .background(UpdatesPalette.page)
        .interactiveDismissDisabled(store.bulkUpdating)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 56, height: 56).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.bulkHasRun ? (store.bulkUpdating ? "正在更新…" : "更新已结束") : "确认更新应用")
                    .font(.system(size: 20, weight: .bold))
                Group {
                    if store.bulkHasRun {
                        Text("已完成 \(store.bulkCompletedCount) 个 · 失败 \(store.bulkFailedCount) 个 · 共 \(store.bulkItems.count) 个")
                    } else {
                        Text("可自动更新 \(store.bulkInstallableCount) 个 · 需官方处理 \(store.bulkItems.count - store.bulkInstallableCount) 个")
                    }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                if store.bulkUpdating {
                    FlowProgressBar(value: store.bulkOverallFraction, height: 4).frame(maxWidth: 260).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Notes

    private struct Note: Identifiable {
        let id: String
        let symbol: String
        let text: String
        var tone: Tone = .neutral
    }

    private var notes: [Note] {
        var notes = [Note(id: "quit", symbol: "doc.badge.clock",
                          text: String(localized: "更新时会请求退出应用，请先保存文稿。直接下载的更新会保留旧版主应用；需要管理员权限时会出现系统授权窗口。"))]
        if store.bulkItems.contains(where: { $0.canInstall && $0.application.isAppStore }) {
            notes.append(Note(id: "store", symbol: "bag",
                              text: String(localized: "商店应用由 Upovi 发起 Apple 服务更新，可能要求 Apple 账户认证。不提供 Upovi 旧版备份或下载暂停；停止只影响后续任务，已交给商店的更新可能继续。")))
        }
        if store.bulkItems.contains(where: { $0.canInstall && $0.candidate.download?.url.pathExtension.lowercased() == "pkg" }) {
            notes.append(Note(id: "pkg", symbol: "exclamationmark.triangle.fill",
                              text: String(localized: "清单包含 PKG 安装包，可运行脚本并修改系统。恢复主应用不能撤销脚本或系统改动。"), tone: .warning))
        }
        return notes
    }

    /// One quiet panel instead of coloured paragraphs; only the icon carries the tone.
    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: note.symbol)
                        .foregroundStyle(note.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(note.tone.color))
                        .frame(width: 16)
                    Text(note.text).foregroundStyle(note.tone == .neutral ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Rows

    private func section(_ title: String, items: [BulkUpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                Text(items.count.formatted()).monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 14 + 32 + 12) }
                    row(item)
                }
            }
            .modifier(UpdatesSurface())
        }
    }

    private func row(_ item: BulkUpdateItem) -> some View {
        HStack(spacing: 12) {
            AppIcon(path: item.application.path, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.application.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    VersionTransition(from: item.application.version, to: item.candidate.version, font: .system(size: 11))
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(item.candidate.source).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                }
                .font(.system(size: 11))
                if let detail = detail(for: item) {
                    Text(detail).font(.system(size: 11)).foregroundStyle(detailColor(for: item))
                        .lineLimit(2).textSelection(.enabled).help(detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.application.path)
            trailing(item)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func trailing(_ item: BulkUpdateItem) -> some View {
        if !item.canInstall {
            Group {
                if item.application.isAppStore {
                    Button("App Store") { store.open(URL(string: "macappstore://showUpdatesPage")) }
                } else if item.application.bundleID == "app.upovi.Upovi" {
                    Button("自身更新") { store.bulkUpdatePresented = false; SelfUpdateService.shared.check() }.disabled(store.bulkUpdating)
                } else if let url = item.candidate.url {
                    Button { store.open(url) } label: { Label("官方来源", systemImage: "arrow.up.forward") }
                }
            }
            .buttonStyle(PillButtonStyle())
        } else if store.bulkHasRun, let (symbol, tone) = indicator(for: item) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tone.color)
                .symbolEffect(.pulse, isActive: store.bulkActiveIDs.contains(item.id) && store.bulkUpdating)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if store.bulkUpdating {
                Button(store.bulkStopRequested ? "正在停止…" : "停止后续更新") { store.stopAllUpdates() }
                    .disabled(store.bulkStopRequested)
                if store.bulkStopRequested {
                    Text("正在安装的应用完成后停止").font(.caption).foregroundStyle(.secondary)
                }
            } else if store.bulkHasRun, let record = store.batchHistory.first(where: { $0.id == store.bulkRecordID }), !record.retryIDs.isEmpty {
                Button("重新检测并重试未完成项") { store.retryBatch(record) }
            }
            Spacer()
            if !store.bulkHasRun, !store.networkAvailable {
                Label("当前没有网络", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
            }
            if !store.bulkUpdating {
                Button(store.bulkHasRun ? "完成" : "取消") { store.bulkUpdatePresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            if !store.bulkHasRun {
                Button("开始更新 \(store.bulkInstallableCount) 个应用") { store.startAllUpdates() }
                    .buttonStyle(PillButtonStyle(prominent: true, large: true)).keyboardShortcut(.defaultAction)
                    .disabled(store.bulkInstallableCount == 0 || !store.networkAvailable)
                    .accessibilityIdentifier("bulk-update-start")
            }
        }
        .buttonStyle(PillButtonStyle(large: true))
    }

    // MARK: Status

    /// Before a run the version line says enough; afterwards each row shows its outcome.
    private func detail(for item: BulkUpdateItem) -> String? {
        if let reason = item.manualReason { return reason }
        guard store.bulkHasRun else { return nil }
        if let outcome = store.bulkOutcomes[item.id] { return outcome.detail }
        if store.bulkUpdating, let transfer = store.transfers[item.id], transfer.isActive { return transfer.label }
        return nil
    }

    private func detailColor(for item: BulkUpdateItem) -> Color {
        switch store.bulkOutcomes[item.id]?.status {
        case .failed: .orange
        case .installed, .current: .green
        default: .secondary
        }
    }

    private func indicator(for item: BulkUpdateItem) -> (String, Tone)? {
        if let outcome = store.bulkOutcomes[item.id] {
            switch outcome.status {
            case .installed, .current: return ("checkmark.circle.fill", .success)
            case .failed: return ("exclamationmark.circle.fill", .warning)
            case .cancelled: return ("minus.circle", .neutral)
            case .manual: return ("arrow.up.forward.app", .neutral)
            }
        }
        if store.bulkUpdating && store.bulkActiveIDs.contains(item.id) { return ("arrow.down.circle.fill", .accent) }
        return nil
    }
}
