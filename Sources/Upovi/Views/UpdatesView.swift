import SwiftUI
import AppKit
import UpoviCore

/// The default landing page: what can be updated right now, and how.
struct UpdatesView: View {
    @Bindable var store: AppStore
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var showPostponed = false

    private var plan: [BulkUpdateItem] {
        BulkUpdatePlan.make(apps: store.apps, results: store.actionableSourceResults, ignored: store.ignored)
            .sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
    }

    var body: some View {
        let plan = plan
        let visible = plan.filter { store.matchesSearch($0.application) }
        let batch = store.bulkSummaryVisible ? store.bulkItems.filter(\.canInstall) : []
        let batchIDs = Set(batch.map(\.id))
        let installable = visible.filter { $0.canInstall && !batchIDs.contains($0.id) }
        let manual = visible.filter { !$0.canInstall && !batchIDs.contains($0.id) }
        let postponed = store.postponedApps.filter { store.matchesSearch($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpdatesOverview(store: store, total: plan.count, installable: plan.filter(\.canInstall).count)
                    .padding(.bottom, 4)
                if store.bulkSummaryVisible {
                    TransferGroup(store: store, items: batch.filter { store.matchesSearch($0.application) }, available: installable)
                }
                if !store.bulkSummaryVisible, !installable.isEmpty {
                    group(String(localized: "可在 Upovi 中更新"), items: installable, showTitle: false)
                }
                if !manual.isEmpty {
                    group(String(localized: "需通过官方渠道更新"), items: manual)
                }
                if !plan.isEmpty, visible.isEmpty, batch.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                }
                if plan.isEmpty, batch.isEmpty { UpdatesPlaceholder(store: store) }
                if !postponed.isEmpty { postponedSection(postponed).entrance(3) }
            }
            .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 48)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .background(UpdatesPalette.page)
        .navigationTitle(Text(verbatim: "Upovi"))
    }

    // MARK: Lists

    private func group(_ title: String, items: [BulkUpdateItem], showTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showTitle { UpdatesSectionHeader(title: title, count: items.count) }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { UpdateRow.separator }
                    UpdateRow(store: store, item: item)
                }
            }.modifier(UpdatesSurface())
        }
    }

    private func postponedSection(_ apps: [InstalledApp]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { showPostponed.toggle() } } label: {
                HStack(spacing: 6) {
                    UpdatesSectionHeader(title: String(localized: "已跳过或稍后提醒"), count: apps.count)
                    Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showPostponed ? (layoutDirection == .rightToLeft ? -90 : 90) : 0))
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showPostponed {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 60) }
                        HStack(spacing: 12) {
                            AppIcon(path: app.path, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 13, weight: .medium))
                                if let candidate = store.fullAssessment(for: app).sourceUpdates.first {
                                    VersionTransition(from: app.version, to: candidate.version, tone: .neutral, font: .caption)
                                }
                            }
                            Spacer()
                            Button("恢复提醒") { restore(app) }.buttonStyle(PillButtonStyle())
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }.modifier(UpdatesSurface()).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func restore(_ app: InstalledApp) {
        for candidate in store.fullAssessment(for: app).sourceUpdates where store.updatePolicy.skipped.contains(UpdatePolicy.key(candidate, app: app)) {
            store.setSkipped(candidate, app: app, skipped: false)
        }
        store.deferUpdates(for: app, until: nil)
    }
}

/// Fills the page while nothing has been found, instead of leaving it blank.
private struct UpdatesPlaceholder: View {
    let store: AppStore

    private var busy: Bool { store.scanning || store.checking || store.refreshing }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.fill.tertiary).frame(width: 72, height: 72)
                if busy {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: store.lastChecked == nil ? "arrow.down.app" : "checkmark.seal")
                        .font(.system(size: 30, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                Text(headline).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 96)
        .animation(.easeOut(duration: 0.2), value: busy)
    }

    private var headline: String {
        if store.scanning { return String(localized: "正在扫描本机应用…") }
        if busy { return String(localized: "正在检查更新…") }
        return store.lastChecked == nil ? String(localized: "检查一下有没有新版本") : String(localized: "没有来源报告的更新")
    }

    private var detail: String {
        if busy || store.lastChecked == nil {
            return String(localized: "Upovi 会扫描 /Applications 与 ~/Applications，再向 Sparkle、Homebrew、GitHub 与 App Store 来源核对版本。")
        }
        return String(localized: "结果为空并不代表所有应用都已是最新")
    }
}

/// Grouped-list section header in the System Settings style.
private struct UpdatesSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(count.formatted()).monospacedDigit().foregroundStyle(.tertiary)
        }
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

struct UpdateRow: View {
    let store: AppStore
    let item: BulkUpdateItem
    var isBatch = false
    @State private var notesExpanded = false

    private static let iconSize: CGFloat = 44
    private static let inset: CGFloat = 16
    private static let spacing: CGFloat = 14

    /// Hairline aligned with the row text, as in inset grouped lists.
    static var separator: some View {
        Divider().padding(.leading, inset + iconSize + spacing)
    }

    private var app: InstalledApp { item.application }
    private var candidate: UpdateCandidate { item.candidate }
    private var transfer: TransferProgress? { store.transfers[app.id] ?? (isBatch ? TransferProgress() : nil) }

    var body: some View {
        let candidate = candidate
        let lead = store.assessment(for: app).communityLeads.first { $0.confirmation == .sourceMatched }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Self.spacing) {
                AppIcon(path: app.path, size: Self.iconSize)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if lead != nil {
                            Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                                .help(String(localized: "相同版本也出现在 P2P 社区报告中"))
                        }
                    }
                    // A running transfer takes over the version line, so the row never changes height.
                    Group {
                        if let transfer, transfer.phase != .installed {
                            TransferStatusLine(transfer: transfer,
                                               detail: store.bulkOutcomes[item.id]?.detail)
                        } else {
                            // Installed rows keep their version line so the result stays readable.
                            HStack(spacing: 6) {
                                VersionTransition(from: app.version, to: candidate.version,
                                                  tone: transfer == nil ? .accent : .success, font: .system(size: 12))
                                Text(verbatim: "·").foregroundStyle(.tertiary)
                                if transfer != nil {
                                    Text("已完成").foregroundStyle(.green).lineLimit(1)
                                } else {
                                    Text(candidate.source).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                                    if let notes = candidate.releaseNotes, !notes.isEmpty {
                                        ReleaseNotesControl(expanded: $notesExpanded).labelStyle(.iconOnly).help("更新说明")
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: 12)).frame(height: 16, alignment: .leading)
                    if let reason = item.manualReason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(reason)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Fixed-height trailing slot: the Update pill turns into a progress ring in place.
                Group {
                    if let transfer {
                        TransferRing(transfer: transfer, cancel: isBatch ? nil : { store.cancelInstallation() })
                            .frame(minWidth: 64)
                    } else {
                        primaryButton(candidate).buttonStyle(PillButtonStyle())
                    }
                }
                .frame(height: 52)
                moreMenu(candidate)
            }
            if notesExpanded, let notes = candidate.releaseNotes, !notes.isEmpty {
                ScrollView { Text(notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220).padding(12)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, Self.iconSize + Self.spacing).padding(.top, 8)
            }
        }
        .padding(.horizontal, Self.inset).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityIdentifier("update-row-\(app.bundleID)")
        .contextMenu { menuItems(candidate) }
    }

    @ViewBuilder private func primaryButton(_ candidate: UpdateCandidate) -> some View {
        if item.canInstall {
            Button("更新") {
                if app.isAppStore { store.reviewStoreUpdate(app, candidate: candidate) } else { store.prepareInstallation(candidate, app: app) }
            }
            .disabled(store.operationBusy)
            .accessibilityIdentifier(app.isAppStore ? "update-store-application" : "download-verify-\(app.bundleID)")
        } else if app.isAppStore {
            Button("App Store") { store.open(URL(string: "macappstore://showUpdatesPage")) }
        } else if app.bundleID == "app.upovi.Upovi" {
            Button("自身更新") { SelfUpdateService.shared.check() }
        } else if let url = candidate.url ?? store.sourceResults[app.id]?.manualURL {
            Button { store.open(url) } label: { Label("官方来源", systemImage: "arrow.up.forward") }
        }
    }

    private func moreMenu(_ candidate: UpdateCandidate) -> some View {
        Menu { menuItems(candidate) } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).background(.fill.tertiary, in: Circle())
        }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("更多操作")
    }

    @ViewBuilder private func menuItems(_ candidate: UpdateCandidate) -> some View {
        Button("跳过此版本") { store.setSkipped(candidate, app: app, skipped: true) }
        Menu("稍后提醒") {
            Button("1 小时后") { store.deferUpdates(for: app, until: Date().addingTimeInterval(3600)) }
            Button("明天") { store.deferUpdates(for: app, until: Date().addingTimeInterval(86400)) }
            Button("一周后") { store.deferUpdates(for: app, until: Date().addingTimeInterval(604800)) }
        }
        Divider()
        if candidate.url != nil { Button("查看更新来源") { store.open(candidate.url) } }
        Button("在全部应用中查看") { store.show(app) }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
        Divider()
        Button("忽略此应用的更新") { store.toggleIgnored(app) }
    }
}

// MARK: Batch progress

/// Batch rows stay listed (even after installing) until the dashboard is dismissed.
private struct TransferGroup: View {
    let store: AppStore
    let items: [BulkUpdateItem]
    let available: [BulkUpdateItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { UpdateRow.separator }
                UpdateRow(store: store, item: item, isBatch: true)
            }
            ForEach(Array(available.enumerated()), id: \.element.id) { index, item in
                if !items.isEmpty || index > 0 { UpdateRow.separator }
                UpdateRow(store: store, item: item)
            }
        }
        .modifier(UpdatesSurface())
    }
}
