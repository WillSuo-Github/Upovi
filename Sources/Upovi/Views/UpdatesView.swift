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
            VStack(alignment: .leading, spacing: 16) {
                Text("可用更新").font(.system(size: 32, weight: .bold))
                    .frame(height: 40, alignment: .leading)
                UpdatesOverview(store: store, total: plan.count, installable: plan.filter(\.canInstall).count)
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
                if !postponed.isEmpty { postponedSection(postponed).entrance(3) }
            }
            .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 40)
            .frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .background(UpdatesPalette.page)
        .navigationTitle(Text(verbatim: "Upovi"))
    }

    // MARK: Lists

    private func group(_ title: String, items: [BulkUpdateItem], showTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showTitle { SectionTitle(title: title, count: items.count) }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().opacity(0.5) }
                    UpdateRow(store: store, item: item)
                }
            }.modifier(UpdatesSurface())
        }
    }

    private func postponedSection(_ apps: [InstalledApp]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { showPostponed.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.forward").font(.caption.weight(.bold))
                        .rotationEffect(.degrees(showPostponed ? (layoutDirection == .rightToLeft ? -90 : 90) : 0))
                    SectionTitle(title: String(localized: "已跳过或稍后提醒"), count: apps.count)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showPostponed {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 64) }
                        HStack(spacing: 12) {
                            AppIcon(path: app.path, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).fontWeight(.medium)
                                if let candidate = store.fullAssessment(for: app).sourceUpdates.first {
                                    VersionTransition(from: app.version, to: candidate.version, tone: .neutral, font: .caption)
                                }
                            }
                            Spacer()
                            Button("恢复提醒") { restore(app) }
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }.card(padding: 0).transition(.opacity.combined(with: .move(edge: .top)))
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

struct UpdateRow: View {
    let store: AppStore
    let item: BulkUpdateItem
    var isBatch = false
    @State private var notesExpanded = false

    private var app: InstalledApp { item.application }
    private var candidate: UpdateCandidate { item.candidate }
    private var transfer: TransferProgress? { store.transfers[app.id] ?? (isBatch ? TransferProgress() : nil) }

    var body: some View {
        let candidate = candidate
        let lead = store.assessment(for: app).communityLeads.first { $0.confirmation == .sourceMatched }
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 16) {
                    HStack(spacing: 24) {
                        AppIcon(path: app.path, size: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(app.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                Text(candidate.source).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                                if lead != nil {
                                    Image(systemName: "person.2").font(.caption).foregroundStyle(.secondary)
                                        .help(String(localized: "相同版本也出现在 P2P 社区报告中"))
                                }
                            }
                            HStack(spacing: 8) {
                                VersionTransition(from: app.version, to: candidate.version, font: .system(size: 14))
                                if let notes = candidate.releaseNotes, !notes.isEmpty {
                                    ReleaseNotesControl(expanded: $notesExpanded).labelStyle(.iconOnly).help("更新说明")
                                }
                            }
                            if let reason = item.manualReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(reason)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if let transfer {
                            TransferMeter(transfer: transfer,
                                detail: transfer.phase == .failed ? store.bulkOutcomes[item.id]?.detail : nil,
                                cancel: isBatch ? nil : { store.cancelInstallation() })
                        } else {
                            HStack { Spacer(minLength: 0); primaryButton(candidate) }.padding(.trailing, 24)
                        }
                    }
                    .frame(width: min(380, max(260, geometry.size.width * 0.40)), height: 56)
                    .overlay(alignment: .topTrailing) {
                        moreMenu(candidate).frame(width: 14).padding(.top, 4)
                    }
                }
                .frame(height: item.manualReason == nil ? 56 : 72)
            }
            .frame(height: item.manualReason == nil ? 56 : 72)
            if notesExpanded, let notes = candidate.releaseNotes, !notes.isEmpty {
                ScrollView { Text(notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220).padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 58).padding(.top, 10)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .contentShape(Rectangle())
        .accessibilityIdentifier("update-row-\(app.bundleID)")
        .contextMenu { menuItems(candidate) }
    }

    @ViewBuilder private func primaryButton(_ candidate: UpdateCandidate) -> some View {
        if item.canInstall {
            Button("更新") {
                if app.isAppStore { store.reviewStoreUpdate(app, candidate: candidate) } else { store.prepareInstallation(candidate, app: app) }
            }
            .buttonStyle(.bordered).controlSize(.regular)
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
        Menu { menuItems(candidate) } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
                if index > 0 { Divider().opacity(0.5) }
                UpdateRow(store: store, item: item, isBatch: true)
            }
            ForEach(Array(available.enumerated()), id: \.element.id) { index, item in
                if !items.isEmpty || index > 0 { Divider().opacity(0.5) }
                UpdateRow(store: store, item: item)
            }
        }
        .modifier(UpdatesSurface())
    }
}
