import SwiftUI
import AppKit
import UpoviCore

/// The default landing page: what can be updated right now, and how.
struct UpdatesView: View {
    @Bindable var store: AppStore
    @State private var showPostponed = false

    private var plan: [BulkUpdateItem] {
        BulkUpdatePlan.make(apps: store.apps, results: store.actionableSourceResults, ignored: store.ignored)
            .sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
    }

    var body: some View {
        let plan = plan
        let visible = plan.filter { store.matchesSearch($0.application) }
        let installable = visible.filter(\.canInstall), manual = visible.filter { !$0.canInstall }
        let postponed = store.postponedApps.filter { store.matchesSearch($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero(total: plan.count, installable: plan.filter(\.canInstall).count).entrance(0)
                if !installable.isEmpty {
                    group("可在 Upovi 中更新", items: installable).entrance(1)
                }
                if !manual.isEmpty {
                    group("需通过官方渠道更新", items: manual).entrance(2)
                }
                if !plan.isEmpty, visible.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                }
                if !postponed.isEmpty { postponedSection(postponed).entrance(3) }
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 72)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .navigationTitle("可用更新")
    }

    // MARK: Hero

    @ViewBuilder private func hero(total: Int, installable: Int) -> some View {
        if total > 0 {
            heroCard(colors: [Theme.sky, Theme.cobalt]) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(total.formatted()).font(Theme.display(64, weight: .heavy)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("个应用有来源更新").font(Theme.display(20, weight: .semibold))
                }
                Text(summary(total: total, installable: installable)).font(.callout).opacity(0.9)
            } actions: {
                Button { store.reviewAllUpdates() } label: { Label("全部更新…", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(store.operationBusy || store.updateCount == 0)
                    .help("下载并安装所有可验证的来源更新；需官方更新的应用将单独列出")
                    .accessibilityIdentifier("update-all-apps")
                Button { store.refreshAll() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                    .buttonStyle(HeroButtonStyle(prominent: false)).disabled(store.operationBusy)
            }
        } else if store.lastChecked == nil {
            heroCard(colors: [Theme.sky, Theme.cobalt]) {
                Text(store.checking ? "正在检查更新…" : "检查一下有没有新版本").font(Theme.display(30, weight: .heavy))
                Text("Upovi 会扫描 /Applications 与 ~/Applications，再向 Sparkle、Homebrew、GitHub 与 App Store 来源核对版本。")
                    .font(.callout).opacity(0.9)
            } actions: {
                Button { store.refreshAll() } label: { Label("立即检查", systemImage: "arrow.clockwise") }
                    .buttonStyle(HeroButtonStyle()).disabled(store.operationBusy)
            }
        } else {
            heroCard(colors: [Color(red: 0.20, green: 0.74, blue: 0.62), Color(red: 0.09, green: 0.50, blue: 0.62)]) {
                Label("没有来源报告的更新", systemImage: "checkmark.seal.fill").font(Theme.display(30, weight: .heavy))
                Text(currentSummary).font(.callout).opacity(0.9)
            } actions: {
                if store.incompleteCheckCount > 0 {
                    Button { store.section = .all; store.sourceFilter = .incomplete } label: { Label("查看检测异常", systemImage: "exclamationmark.triangle") }
                        .buttonStyle(HeroButtonStyle())
                }
                Button { store.refreshAll() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                    .buttonStyle(HeroButtonStyle(prominent: store.incompleteCheckCount == 0)).disabled(store.operationBusy)
            }
        }
    }

    private func heroCard<Content: View, Actions: View>(colors: [Color], @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
            HStack(spacing: 10) { actions() }.padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground(colors: colors))
        .shadow(color: (colors.last ?? .clear).opacity(0.25), radius: 18, y: 8)
    }

    private func summary(total: Int, installable: Int) -> String {
        var parts = ["\(installable) 个可由 Upovi 验证并安装"]
        if total > installable { parts.append("\(total - installable) 个需官方渠道") }
        if let date = store.lastChecked { parts.append("上次检查 \(date.relativeDescription)") }
        return parts.joined(separator: " · ")
    }

    private var currentSummary: String {
        var parts: [String] = []
        if let date = store.lastChecked { parts.append("上次检查 \(date.relativeDescription)") }
        if store.incompleteCheckCount > 0 { parts.append("\(store.incompleteCheckCount) 个应用未能完整检查") }
        parts.append("结果为空并不代表所有应用都已是最新")
        return parts.joined(separator: " · ")
    }

    // MARK: Lists

    private func group(_ title: String, items: [BulkUpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title, count: items.count)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 76) }
                    UpdateRow(store: store, item: item)
                }
            }.card(padding: 0)
        }
    }

    private func postponedSection(_ apps: [InstalledApp]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { showPostponed.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).rotationEffect(.degrees(showPostponed ? 90 : 0))
                    SectionTitle(title: "已跳过或稍后提醒", count: apps.count)
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

private struct UpdateRow: View {
    let store: AppStore
    let item: BulkUpdateItem
    @State private var notesExpanded = false

    private var app: InstalledApp { item.application }
    private var candidate: UpdateCandidate { item.candidate }

    var body: some View {
        let candidate = candidate
        let lead = store.assessment(for: app).communityLeads.first { $0.confirmation == .sourceMatched }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AppIcon(path: app.path, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(app.name).font(.headline).lineLimit(1)
                        StatusBadge(text: candidate.source, tone: .neutral)
                        if lead != nil { StatusBadge(text: "社区一致", symbol: "person.2.fill", tone: .community).help("相同版本也出现在 P2P 社区报告中") }
                    }
                    VersionTransition(from: app.version, to: candidate.version)
                    if let reason = item.manualReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                primaryButton(candidate)
                moreMenu(candidate)
            }
            if let notes = candidate.releaseNotes, !notes.isEmpty {
                Button { withAnimation(.snappy) { notesExpanded.toggle() } } label: {
                    Label(notesExpanded ? "收起更新说明" : "更新说明", systemImage: notesExpanded ? "chevron.up" : "text.alignleft")
                        .font(.caption.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.leading, 58)
                if notesExpanded {
                    ScrollView { Text(notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220).padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.leading, 58)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu { menuItems(candidate) }
    }

    @ViewBuilder private func primaryButton(_ candidate: UpdateCandidate) -> some View {
        if item.canInstall {
            Button(app.isAppStore ? "更新" : "下载并验证") {
                if app.isAppStore { store.reviewStoreUpdate(app, candidate: candidate) } else { store.prepareInstallation(candidate, app: app) }
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
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
