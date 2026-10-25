import SwiftUI

struct CommunityView: View {
    @Bindable var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("自动发现，让版本信息流动起来", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.largeTitle.bold()).foregroundStyle(.tint)
                Text("自动寻找共享同一应用的公网节点，无需添加联系人或交换邀请。")
                    .foregroundStyle(.secondary)
                GroupBox("网络状态") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(store.networkEnabled ? "P2P 已开启" : "P2P 已关闭", systemImage: store.networkEnabled ? "network" : "network.slash")
                            Spacer()
                            SettingsLink { Text("P2P 设置…") }
                        }
                        Text("P2P 在设置中统一控制。开启后自动发现并公开共享所有已扫描应用的版本信息，任何人均可读取，节点也能看到 IP；不包含路径、用户名、设备名或安装包。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        HStack {
                            Label("自动覆盖 \(store.apps.count) 个已扫描应用", systemImage: "square.grid.2x2")
                            Spacer()
                            Button("立即自动发现") { store.beginSync() }.buttonStyle(.borderedProminent)
                                .disabled(!store.networkEnabled || store.p2pTransitioning || store.syncing || store.scanning || store.installing)
                        }
                        if store.syncing { HStack { ProgressView().controlSize(.small); Text(store.p2pProgress).font(.caption) } }
                        Text(store.networkStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let date = store.lastSynced { Text("最近发现：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10)
                }
                if !store.communityApps.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("社区版本线索").font(.title3.bold())
                        Text("未经来源确认的报告不计入可用更新，也不发送通知。多个节点一致仍不能证明版本真实。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("核对更新来源") { store.beginChecking() }
                            .disabled(store.checking || store.scanning || store.installing)
                        ForEach(store.communityApps) { app in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(app.name).font(.headline)
                                    Spacer()
                                    Button("查看应用") { store.section = .all; store.selection = app.id }
                                }
                                ForEach(store.assessment(for: app).communityLeads) { CommunityLeadView(lead: $0) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("自动发现的共享节点").font(.title3.bold())
                    if store.discoveredPublishers.isEmpty {
                        Label("尚未收到共享节点的有效记录", systemImage: "network")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                        Text("开启全局 P2P 后，所有已扫描应用会自动参与。仍需其他用户共享相同应用，且公网 DHT 中有可用记录；没有记录不代表应用已经最新。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.discoveredPublishers.values.sorted { $0.shortID < $1.shortID }) { peer in
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("公开节点 \(peer.shortID)").font(.headline)
                                    Text(peer.applications.sorted().joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(peer.lastSeen, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                GroupBox("共享规则") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("自动查找公开发布者索引，读取 DHT 记录并独立验签", systemImage: "checkmark.shield")
                        Label("应用运行时自动同步，依次覆盖所有已扫描应用", systemImage: "clock")
                        Label("社区报告不增加更新数量，不触发更新通知", systemImage: "checkmark.seal")
                        Text("公开索引只是可被篡改、挤占的发现线索，不是可信目录。版本报告必须由发布者独立签名，但仍不能证明真实安装或开发者背书。关闭共享会停止服务与后续登记，已缓存的记录无法立即撤回。DHT 存取可绕过入站端口限制；UDP 网络不可用或索引受干扰时仍可能失败。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }.padding(32).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("P2P 自动发现")
    }
}
