import SwiftUI
import AppKit
import UpoviCore

struct AppDetailView: View {
    @Bindable var store: AppStore
    @State private var sourceEditor = false

    var body: some View {
        ScrollView {
            if let app = store.selectedApp {
                VStack(alignment: .leading, spacing: 22) {
                    header(app)
                    statusSection(app)
                    let leads = store.assessment(for: app).communityLeads
                    if !leads.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: String(localized: "社区版本线索"), count: leads.count)
                            ForEach(leads) { CommunityLeadView(lead: $0) }
                        }
                    }
                    info(app)
                    source(app)
                    actions(app)
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .id(app.id)
            } else {
                ContentUnavailableView("选择一个应用", systemImage: "app.dashed", description: Text("在左侧列表中选择应用，查看版本、来源与更新操作。"))
                    .padding(.top, 120)
            }
        }
        .sheet(isPresented: $sourceEditor) { if let app = store.selectedApp { SourceEditorView(store: store, app: app) } }
    }

    private func header(_ app: InstalledApp) -> some View {
        let status = store.status(for: app)
        return HStack(alignment: .center, spacing: 14) {
            AppIcon(path: app.path, size: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(Theme.display(20)).textSelection(.enabled).lineLimit(2)
                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                StatusBadge(text: status.shortLabel, symbol: status.symbol, tone: status.tone)
            }
        }
    }

    // MARK: Status

    @ViewBuilder private func statusSection(_ app: InstalledApp) -> some View {
        let candidates = store.fullAssessment(for: app).sourceUpdates
        if !candidates.isEmpty {
            VStack(spacing: 12) {
                ForEach(candidates) { UpdateCandidateCard(store: store, app: app, candidate: $0) }
            }
        } else if app.isAppStore, let id = store.sourceResults[app.id]?.appStoreID {
            statusCard(symbol: "bag.fill", tone: .accent, title: String(localized: "App Store 应用"),
                       message: String(localized: "可以通过 Apple 商店服务检查并更新；可能需要拥有该应用的 Apple 账户认证。")) {
                Button("检查并更新此应用") {
                    store.reviewStoreUpdate(app, candidate: .init(version: app.version, source: "App Store", isCommunity: false, url: nil, appStoreID: id))
                }
                .buttonStyle(.borderedProminent).disabled(store.operationBusy)
                .accessibilityIdentifier("check-update-store-application")
            }
        } else {
            let result = store.sourceResults[app.id]
            switch store.status(for: app) {
            case .ignored:
                statusCard(symbol: "eye.slash", tone: .neutral, title: String(localized: "已忽略更新提醒"), message: String(localized: "此应用不会出现在可用更新、全部更新和通知中。")) {
                    Button("恢复更新提醒") { store.toggleIgnored(app) }
                }
            case .current, .appStore:
                statusCard(symbol: "checkmark.circle.fill", tone: .success, title: String(localized: "来源未报告新版本"),
                           message: store.lastChecked.map { String(localized: "最近一次检查（\($0.relativeDescription)）没有发现更高版本。") } ?? "") { EmptyView() }
            case .failed, .partial:
                statusCard(symbol: "exclamationmark.triangle.fill", tone: .warning, title: String(localized: "检测未完成"),
                           message: String(localized: "部分或全部来源没有返回有效结果，原因见下方“检测来源”。可以稍后重新检查，或在帮助菜单导出诊断报告。")) {
                    Button("重新检查全部") { store.beginChecking() }.disabled(store.operationBusy)
                }
            case .unsupported:
                statusCard(symbol: "questionmark.circle.fill", tone: .neutral, title: String(localized: "未找到可用的更新来源"),
                           message: String(localized: "可以手动指定开发者的 appcast 或官方 GitHub 仓库。")) {
                    Button("设置更新来源…") { sourceEditor = true }.buttonStyle(.borderedProminent)
                    if let url = result?.manualURL { Button("官方更新入口") { store.open(url) } }
                }
            case .community:
                statusCard(symbol: "person.2.fill", tone: .community, title: String(localized: "只有社区线索"),
                           message: String(localized: "社区报告未获更新来源确认，不计入可用更新，也不能用于安装。")) {
                    Button("核对更新来源") { store.beginChecking() }.disabled(store.operationBusy)
                }
            default:
                statusCard(symbol: "circle.dashed", tone: .neutral, title: String(localized: "尚未检查"), message: String(localized: "刷新并检查后会显示此应用的来源结果。")) {
                    Button("检查更新") { store.beginChecking() }.disabled(store.operationBusy)
                }
            }
        }
    }

    private func statusCard<Actions: View>(symbol: String, tone: Tone, title: String, message: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tone == .neutral ? Color.primary : tone.color)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) { actions() }
        }.card(padding: 14, tint: tone == .neutral ? nil : tone.color)
    }

    // MARK: Info

    private func info(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "应用信息"))
            VStack(spacing: 0) {
                row(String(localized: "当前版本"), app.version, mono: true)
                row(String(localized: "构建号"), app.build.isEmpty ? String(localized: "未知") : app.build, mono: true)
                row(String(localized: "分发渠道"), app.isAppStore ? "App Store" : String(localized: "开发者分发"))
                row("Team ID", app.teamID ?? String(localized: "未识别"), mono: app.teamID != nil)
                row(String(localized: "安装位置"), app.path, last: true)
            }.card(padding: 0)
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value).font(mono ? .callout.monospaced() : .callout).multilineTextAlignment(.trailing)
                    .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            }.font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
            if !last { Divider().padding(.leading, 14) }
        }
    }

    private func source(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "检测来源"))
            VStack(alignment: .leading, spacing: 8) {
                Text(store.sourceResults[app.id]?.note ?? String(localized: "尚未检查开发者更新源")).font(.callout).textSelection(.enabled)
                if let feed = store.sourceOverrides[app.bundleID]?.appcast ?? app.feedURL {
                    Label(feed.absoluteString, systemImage: "dot.radiowaves.up.forward").font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                if let repository = store.sourceOverrides[app.bundleID]?.githubRepository {
                    Label(repository, systemImage: "chevron.left.forwardslash.chevron.right").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("设置更新来源…") { sourceEditor = true }.buttonStyle(.link)
                    if let url = store.sourceResults[app.id]?.manualURL { Button("官方更新入口") { store.open(url) }.buttonStyle(.link) }
                }.font(.callout)
            }.card(padding: 14)
        }
    }

    private func actions(_ app: InstalledApp) -> some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            Button { store.toggleIgnored(app) } label: {
                Label(store.ignored.contains(app.bundleID) ? "恢复更新提醒" : "忽略更新提醒",
                      systemImage: store.ignored.contains(app.bundleID) ? "eye" : "eye.slash")
            }
        }.controlSize(.small)
    }
}

/// A source-reported version with its install action and reminder controls.
private struct UpdateCandidateCard: View {
    let store: AppStore
    let app: InstalledApp
    let candidate: UpdateCandidate
    @State private var notes = false

    var body: some View {
        let skipped = store.updatePolicy.skipped.contains(UpdatePolicy.key(candidate, app: app))
        let deferred = store.updatePolicy.deferredUntil[UpdatePolicy.scope(app)].flatMap { $0 > store.policyClock ? $0 : nil }
        let muted = skipped || deferred != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(muted ? "已跳过或推迟" : "可更新").font(.caption.weight(.semibold)).foregroundStyle(muted ? Color.secondary : Theme.accent)
                Spacer()
                StatusBadge(text: candidate.source)
            }
            VersionTransition(from: app.version, to: candidate.version, tone: muted ? .neutral : .accent, font: Theme.display(17, weight: .medium))
            if let deferred { Text("稍后提醒至 \(deferred.display())").font(.caption).foregroundStyle(.secondary) }
            if let text = candidate.releaseNotes, !text.isEmpty {
                DisclosureGroup("更新说明", isExpanded: $notes) {
                    Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.callout)
            }
            HStack(spacing: 8) {
                if muted {
                    if skipped { Button("恢复此版本提醒") { store.setSkipped(candidate, app: app, skipped: false) } }
                    if deferred != nil { Button("取消稍后提醒") { store.deferUpdates(for: app, until: nil) } }
                } else {
                    primary
                    Menu("稍后") {
                        Button("跳过此版本") { store.setSkipped(candidate, app: app, skipped: true) }
                        Divider()
                        Button("1 小时后提醒") { store.deferUpdates(for: app, until: Date().addingTimeInterval(3600)) }
                        Button("明天提醒") { store.deferUpdates(for: app, until: Date().addingTimeInterval(86400)) }
                        Button("一周后提醒") { store.deferUpdates(for: app, until: Date().addingTimeInterval(604800)) }
                    }
                    .fixedSize()
                    .help("到期后，在下一次来源检查时恢复提醒；需要应用正在运行且通知已启用。")
                }
            }
            if !muted, store.action(for: candidate, app: app) == .official {
                Text("此更新请使用官方来源或应用内更新。").font(.caption).foregroundStyle(.secondary)
            }
        }.card(padding: 14, tint: muted ? nil : Theme.accent)
    }

    @ViewBuilder private var primary: some View {
        switch store.action(for: candidate, app: app) {
        case .store:
            Button("在 Upovi 中更新") { store.reviewStoreUpdate(app, candidate: candidate) }
                .buttonStyle(.borderedProminent).disabled(store.operationBusy)
                .accessibilityIdentifier("update-store-application")
        case .verifiedDownload:
            Button("更新") { store.prepareInstallation(candidate, app: app) }
                .buttonStyle(.borderedProminent).disabled(store.operationBusy)
        case .official:
            if candidate.url != nil {
                Button { store.open(candidate.url) } label: { Label("查看更新来源", systemImage: "arrow.up.forward") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct CommunityLeadView: View {
    let lead: CommunityLead

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lead.report.version).font(.headline.monospacedDigit())
                if !lead.report.build.isEmpty { Text("(\(lead.report.build))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                StatusBadge(text: confirmation.label, symbol: confirmation.symbol, tone: confirmation.tone)
            }
            Text(lead.confirmation == .sourceMatched
                 ? String(localized: "相同版本已由 \(lead.matchingSources.joined(separator: "、")) 提供。更新数量、通知与安装以来源结果为准。")
                 : String(localized: "未获更新来源确认，不计入更新数量，不发送更新通知。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                Text("\(lead.publisherCount) 个节点 · \(lead.report.observedAt.relativeDescription)")
            }.font(.caption).foregroundStyle(.tertiary)
                .help("节点数量不代表独立用户，节点签名也不能证明真实安装。Upovi 不使用 P2P 分发安装包。")
        }.card(padding: 12, tint: Tone.community.color)
    }

    private var confirmation: (label: String, symbol: String, tone: Tone) {
        switch lead.confirmation {
        case .unverified: (String(localized: "未经核实"), "questionmark.circle", .neutral)
        case .multiplePublishers: (String(localized: "多节点 · 未核实"), "person.3", .community)
        case .sourceMatched: (String(localized: "来源一致"), "checkmark.seal.fill", .success)
        }
    }
}
