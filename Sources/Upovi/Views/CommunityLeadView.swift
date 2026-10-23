import SwiftUI
import UpoviCore

struct CommunityLeadView: View {
    let lead: CommunityLead

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("社区报告 \(lead.report.version)", systemImage: "person.2")
                .font(.headline).foregroundStyle(.orange)
            if !lead.report.build.isEmpty {
                Text("构建号：\(lead.report.build)").font(.caption.monospacedDigit())
            }
            Text(confirmationLabel).font(.callout.bold())
            if lead.confirmation == .sourceMatched {
                Text("相同版本已由 \(lead.matchingSources.joined(separator: "、")) 提供。更新数量、通知与安装以来源结果为准。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("未获更新来源确认，不计入更新数量，不发送更新通知。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(lead.publisherCount) 个节点报告；节点数量不代表独立用户，节点签名也不能证明真实安装。")
                .font(.caption).foregroundStyle(.secondary)
            Text("Upovi 不使用 P2P 分发安装包。").font(.caption).foregroundStyle(.secondary)
            Text(lead.report.observedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var confirmationLabel: String {
        switch lead.confirmation {
        case .unverified: "未经核实的社区报告"
        case .multiplePublishers: "多个节点报告 · 未经核实"
        case .sourceMatched: "来源核对一致"
        }
    }
}
