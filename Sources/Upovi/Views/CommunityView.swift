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
                GroupBox("检测与共享") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("启用公网 P2P 自动发现", isOn: $store.networkEnabled)
                        Toggle("公开共享选中应用的版本", isOn: $store.sharingEnabled)
                            .disabled(!store.sharingEnabled && (!store.networkEnabled || store.syncing))
                        Text("公开共享默认关闭。开启后，任何人都可以读取选中应用的标识、版本、构建号、分发渠道和自报 Team ID。不会发布路径、用户名、设备名称或安装包。网络节点仍可看到你的 IP，这不是匿名网络。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        HStack {
                            Label("范围：\(store.selectedBundles.count) 个应用", systemImage: "checkmark.square")
                            Spacer()
                            Button("选择应用") { store.section = .all }
                            Button("立即自动发现") { store.beginSync() }.buttonStyle(.borderedProminent)
                                .disabled(!store.networkEnabled || store.syncing || store.scanning)
                        }
                        if store.syncing { HStack { ProgressView().controlSize(.small); Text(store.p2pProgress).font(.caption) } }
                        Text(store.networkStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let date = store.lastSynced { Text("最近发现：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("自动发现的共享节点").font(.title3.bold())
                    if store.discoveredPublishers.isEmpty {
                        Label("尚未收到共享节点的有效记录", systemImage: "network")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                        Text("选择检测范围并启用自动发现即可。需要其他用户主动共享同一应用，并且公网 DHT 中仍有可用记录；没有记录不代表应用已经最新。")
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
                        Label("应用运行时每 10 分钟尝试发现与续期", systemImage: "clock")
                        Label("社区高版本只作为线索，仍需到官方渠道核实", systemImage: "checkmark.seal")
                        Text("公开索引只是可被篡改、挤占的发现线索，不是可信目录。版本报告必须由发布者独立签名，但仍不能证明真实安装或开发者背书。关闭共享会停止服务与后续登记，已缓存的记录无法立即撤回。DHT 存取可绕过入站端口限制；UDP 网络不可用或索引受干扰时仍可能失败。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }.padding(32).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("P2P 自动发现")
    }
}
