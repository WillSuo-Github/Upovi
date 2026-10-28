import SwiftUI

/// Page header: a large title above one fixed-height status card, in the spirit of
/// System Settings › Software Update. Every state (scanning, checking, batch, idle) fills the
/// same three slots — glyph, title/detail, action — so the header never changes height.
struct UpdatesOverview: View {
    let store: AppStore
    let total: Int
    let installable: Int

    private var status: UpdatesStatus { UpdatesStatus(store: store, total: total, installable: installable) }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 12) {
            Text("可用更新").font(.system(size: 28, weight: .bold)).lineLimit(1)
                .frame(height: 34, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 14) {
                StatusGlyph(glyph: status.glyph)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.system(size: 14, weight: .semibold))
                        .monospacedDigit().lineLimit(1)
                    HStack(spacing: 0) {
                        Text(status.detail).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).truncationMode(.tail).help(status.detail)
                        if status.showsRate {
                            Text(verbatim: " · ").foregroundStyle(.tertiary)
                            DownloadRate(transfers: Array(store.transfers.values), total: true, compact: true)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: status.title)
                UpdatesOverviewActions(store: store, total: total)
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            .modifier(UpdatesSurface())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updates-overview")
    }
}

/// Everything the header shows, derived from store state in one place.
private struct UpdatesStatus {
    enum Glyph: Equatable {
        case spinner
        case progress(Double, Tone)
        case symbol(String, Tone)
    }

    var glyph: Glyph
    var title: String
    var detail: String
    var showsRate = false

    @MainActor init(store: AppStore, total: Int, installable: Int) {
        let apps = store.apps.count
        if store.bulkSummaryVisible {
            var parts = [String(localized: "已完成 \(store.bulkFinishedCount) / \(store.bulkInstallableCount)")]
            if !store.bulkUpdating, store.bulkCompletedCount != store.bulkFinishedCount {
                parts.append(String(localized: "成功 \(store.bulkCompletedCount)"))
            }
            if store.bulkFailedCount > 0 { parts.append(String(localized: "失败 \(store.bulkFailedCount)")) }
            detail = parts.joined(separator: " · ")
            if store.bulkUpdating {
                glyph = .progress(store.bulkOverallFraction, .accent)
                title = store.bulkStopRequested ? String(localized: "正在停止…")
                    : String(localized: "正在更新 \(store.bulkInstallableCount) 个应用")
                showsRate = !store.bulkStopRequested
            } else if store.bulkCompletedCount == store.bulkInstallableCount {
                glyph = .symbol("checkmark.circle.fill", .success)
                title = String(localized: "全部更新完成")
            } else {
                glyph = .symbol("exclamationmark.circle.fill", .warning)
                title = String(localized: "更新已结束")
            }
        } else if store.scanning {
            glyph = .spinner
            title = String(localized: "正在扫描本机应用…")
            detail = apps > 0 ? String(localized: "\(apps) 个本机应用") : ""
        } else if store.refreshing && !store.checking {
            glyph = .spinner
            title = String(localized: "正在连接更新来源…")
            detail = String(localized: "\(apps) 个本机应用")
        } else if store.checking {
            glyph = apps > 0 ? .progress(Double(store.completedChecks) / Double(apps), .accent) : .spinner
            title = String(localized: "正在检查更新…")
            var parts = [String(localized: "完成 \(store.completedChecks)/\(apps)")]
            if total > 0 { parts.append(String(localized: "\(total) 个应用有来源更新")) }
            detail = parts.joined(separator: " · ")
        } else if total > 0 {
            glyph = .symbol("arrow.down.circle.fill", .accent)
            title = String(localized: "\(total) 个应用有来源更新")
            var parts = [String(localized: "\(installable) 个可由 Upovi 验证并安装")]
            if total > installable { parts.append(String(localized: "\(total - installable) 个需官方渠道")) }
            if let date = store.lastChecked { parts.append(String(localized: "上次检查 \(date.relativeDescription)")) }
            detail = parts.joined(separator: " · ")
        } else if let date = store.lastChecked {
            glyph = .symbol("checkmark.circle.fill", .success)
            title = String(localized: "没有来源报告的更新")
            var parts = [String(localized: "上次检查 \(date.relativeDescription)")]
            if store.incompleteCheckCount > 0 {
                parts.append(String(localized: "\(store.incompleteCheckCount) 个应用未能完整检查"))
            }
            parts.append(String(localized: "结果为空并不代表所有应用都已是最新"))
            detail = parts.joined(separator: " · ")
        } else {
            glyph = .symbol("arrow.down.circle", .neutral)
            title = String(localized: "检查一下有没有新版本")
            detail = String(localized: "Upovi 会扫描 /Applications 与 ~/Applications，再向 Sparkle、Homebrew、GitHub 与 App Store 来源核对版本。")
        }
    }
}

/// 32 pt leading glyph: an indeterminate spinner, a determinate ring, or a filled symbol.
private struct StatusGlyph: View {
    let glyph: UpdatesStatus.Glyph
    private let size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch glyph {
            case .spinner:
                Circle().stroke(.quaternary, lineWidth: 3)
                if reduceMotion {
                    ProgressView().controlSize(.small)
                } else {
                    TimelineView(.animation) { context in
                        Circle().trim(from: 0, to: 0.28)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 1) * 360))
                    }
                }
            case let .progress(value, tone):
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle().trim(from: 0, to: min(1, max(0.02, value.isFinite ? value : 0)))
                    .stroke(tone.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: value)
            case let .symbol(name, tone):
                Image(systemName: name).font(.system(size: size - 2))
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: size - 4, height: size - 4)
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.3), value: glyph)
        .accessibilityHidden(true)
    }
}

/// The single action slot on the right of the status card.
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
                        .buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            } else if store.checking || store.refreshing {
                Button("取消") { store.cancelChecking() }
            } else if store.scanning {
                EmptyView()
            } else if total > 0 {
                Button("全部更新…") { store.reviewAllUpdates() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(store.operationBusy)
                    .help("下载并安装所有可验证的来源更新；需官方更新的应用将单独列出")
                    .accessibilityIdentifier("update-all-apps")
            } else {
                if store.incompleteCheckCount > 0 {
                    Button("查看检测异常") { store.section = .all; store.sourceFilter = .incomplete }
                }
                Button("重新检查") { store.refreshAll() }.disabled(store.operationBusy)
            }
        }
        .buttonStyle(PillButtonStyle())
        .fixedSize()
    }
}
