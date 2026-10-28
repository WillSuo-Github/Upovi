import SwiftUI
import UpoviCore

struct CommunityView: View {
    @Bindable var store: AppStore
    @State private var detailsExpanded = false
    @State private var rulesExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero.entrance(0)
                if store.networkEnabled {
                    stats.entrance(1)
                    leads.entrance(2)
                    peers.entrance(3)
                }
                rules.entrance(4)
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 72)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .navigationTitle("P2P 网络")
        .onAppear { if !store.networkEnabled { rulesExpanded = true } }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 22) {
            NetworkOrb(active: store.networkEnabled, syncing: store.syncing)
            VStack(alignment: .leading, spacing: 8) {
                Text(store.networkEnabled ? "P2P 版本发现已开启" : "P2P 版本发现已关闭").font(Theme.display(26, weight: .heavy))
                Text(store.networkEnabled
                     ? "自动寻找共享同一应用的公网节点，交换已签名的版本报告。社区报告只是线索，不计入可用更新，也不会用于安装。"
                     : "开启后，Upovi 会通过 BitTorrent DHT 与其他用户交换已扫描应用的版本信息，帮助更早发现新版本。")
                    .font(.callout).opacity(0.9).fixedSize(horizontal: false, vertical: true)
                if store.syncing, !store.p2pProgress.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small).tint(.white); Text(store.p2pProgress).font(.caption.monospacedDigit()) }
                } else if let date = store.lastSynced, store.networkEnabled {
                    Text("最近同步 \(date.relativeDescription)").font(.caption).opacity(0.8)
                }
                HStack(spacing: 10) {
                    if store.networkEnabled {
                        Button { store.beginSync() } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(HeroButtonStyle())
                            .disabled(store.p2pTransitioning || store.syncing || store.scanning || store.installing)
                        SettingsLink { Label("P2P 设置", systemImage: "gearshape") }.buttonStyle(HeroButtonStyle(prominent: false))
                    } else {
                        SettingsLink { Label("在设置中开启", systemImage: "power") }.buttonStyle(HeroButtonStyle())
                    }
                }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground(colors: store.networkEnabled
            ? [Color(red: 0.13, green: 0.55, blue: 0.85), Color(red: 0.12, green: 0.24, blue: 0.62)]
            : [Color(white: 0.45), Color(white: 0.28)]))
    }

    private var stats: some View {
        let leadCount = store.communityApps.reduce(0) { $0 + store.assessment(for: $1).communityLeads.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatTile(value: store.discoveredPublishers.count.formatted(), label: String(localized: "验签节点"), symbol: "person.2.wave.2")
                StatTile(value: store.p2pScope.count.formatted(), label: String(localized: "参与共享的应用"), symbol: "square.grid.2x2", tone: .success)
                StatTile(value: leadCount.formatted(), label: String(localized: "更高版本线索"), symbol: "sparkles", tone: .community)
                StatTile(value: store.lastSynced.map { $0.display(date: .omitted) } ?? "—", label: String(localized: "最近同步"), symbol: "clock")
            }
            DisclosureGroup("同步详情", isExpanded: $detailsExpanded) {
                Text(store.networkStatus).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.callout)
        }
    }

    // MARK: Leads & peers

    @ViewBuilder private var leads: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: String(localized: "社区版本线索"), count: store.communityApps.count)
                Button("核对更新来源") { store.beginChecking() }
                    .disabled(store.checking || store.scanning || store.installing)
                    .help("向开发者来源核对；一致的版本会标记为“来源一致”")
            }
            if store.communityApps.isEmpty {
                Text("暂时没有比本机更高的社区版本报告。没有线索不代表应用已经最新。")
                    .font(.callout).foregroundStyle(.secondary).card(padding: 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.communityApps.enumerated()), id: \.element.id) { index, app in
                        VStack(spacing: 0) {
                            if index > 0 { Divider().padding(.leading, 66) }
                            LeadRow(store: store, app: app)
                        }
                        .transition(.listRow)
                    }
                }.card(padding: 0)
                .listAnimation(store.communityApps.map(\.id))
            }
        }
    }

    @ViewBuilder private var peers: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "已发现的公开节点"), count: store.discoveredPublishers.count)
            if store.discoveredPublishers.isEmpty {
                Text("尚未收到共享节点的有效记录。需要其他用户共享相同应用，且公网 DHT 中有可用记录。")
                    .font(.callout).foregroundStyle(.secondary).card(padding: 16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(store.discoveredPublishers.values.sorted { $0.lastSeen > $1.lastSeen }) { peer in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "key.horizontal.fill").foregroundStyle(Theme.accent)
                                Text(peer.shortID).font(.callout.monospaced().weight(.semibold))
                                Spacer()
                                Text(peer.lastSeen.relativeDescription).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(peer.applications.sorted().joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.card(padding: 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .listAnimation(store.discoveredPublishers.values.sorted { $0.lastSeen > $1.lastSeen }.map(\.id))
            }
        }
    }

    private var rules: some View {
        DisclosureGroup(isExpanded: $rulesExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Label("公开信息包括应用标识、版本、构建号、分发渠道和自报 Team ID，任何人均可读取；节点也能看到 IP。不包含路径、用户名、设备名或安装包。", systemImage: "eye")
                Label("版本报告由发布者独立签名，但签名不能证明真实安装或开发者背书；节点数量也不代表独立用户。", systemImage: "checkmark.shield")
                Label("社区报告不增加更新数量，不触发更新通知，也不提供下载链接。Upovi 不使用 P2P 分发安装包。", systemImage: "checkmark.seal")
                Label("公开索引可被篡改或挤占；关闭共享会停止服务与后续登记，已缓存的记录无法立即撤回，最长 24 小时内过期。", systemImage: "exclamationmark.triangle")
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        } label: {
            Label("隐私与信任说明", systemImage: "lock.shield").font(.headline)
        }.card(padding: 16)
    }
}

private struct LeadRow: View {
    let store: AppStore
    let app: InstalledApp

    var body: some View {
        let leads = store.assessment(for: app).communityLeads
        HStack(alignment: .center, spacing: 14) {
            AppIcon(path: app.path, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline)
                if let lead = leads.first {
                    HStack(spacing: 8) {
                        VersionTransition(from: app.version, to: lead.report.version, tone: .community, font: .caption)
                        Text("\(lead.publisherCount) 个节点 · \(lead.report.observedAt.relativeDescription)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if let lead = leads.first {
                switch lead.confirmation {
                case .sourceMatched: StatusBadge(text: String(localized: "来源一致"), symbol: "checkmark.seal.fill", tone: .success)
                case .multiplePublishers: StatusBadge(text: String(localized: "多节点 · 未核实"), symbol: "person.3", tone: .community)
                case .unverified: StatusBadge(text: String(localized: "未经核实"), symbol: "questionmark.circle")
                }
            }
            Button("查看应用") { store.show(app) }.controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Concentric pulsing rings signal live participation.
private struct NetworkOrb: View {
    let active: Bool
    let syncing: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<3) { ring in
                Circle().strokeBorder(.white.opacity(active ? 0.35 - Double(ring) * 0.1 : 0.15), lineWidth: 1.5)
                    .frame(width: 56 + CGFloat(ring) * 22, height: 56 + CGFloat(ring) * 22)
                    .scaleEffect(pulse && active && !reduceMotion ? 1.08 : 1)
                    .animation(active && !reduceMotion ? .easeInOut(duration: syncing ? 0.8 : 1.8).repeatForever().delay(Double(ring) * 0.2) : .default, value: pulse)
            }
            Image(systemName: active ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 56, height: 56).background(.white.opacity(0.2), in: Circle())
        }
        .frame(width: 110, height: 110)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}
