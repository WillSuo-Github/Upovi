import SwiftUI
import UpoviCore

struct DownloadTasksView: View {
    let store: AppStore
    private var records: [DownloadRecord] {
        store.downloadCenter.records.filter { store.search.isEmpty || $0.applicationName.localizedCaseInsensitiveContains(store.search) || $0.bundleID.localizedCaseInsensitiveContains(store.search) }
    }
    var body: some View {
        let records = records
        let active = records.filter { $0.state.active }, finished = records.filter { !$0.state.active }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "下载", subtitle: "暂停会保留进度；断网后等待重连，临时网络错误最多自动重试 3 次。安装仍需单独确认。").entrance(0)
                if store.downloadCenter.historySaveFailed {
                    Label("下载记录未能保存；当前任务仍可操作，退出后可能缺少记录。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).card(padding: 12, tint: .orange)
                }
                if records.isEmpty {
                    ContentUnavailableView(store.search.isEmpty ? "暂无下载任务" : "没有匹配的下载", systemImage: "tray.and.arrow.down",
                                           description: Text("在“可用更新”中选择“下载并验证”或“全部更新”，任务会显示在这里。"))
                        .padding(.top, 60)
                }
                if !active.isEmpty { list("进行中", active).entrance(1) }
                if !finished.isEmpty { list("最近", finished).entrance(2) }
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 72)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .navigationTitle("下载")
        .task { store.downloadCenter.start() }
    }

    private func list(_ title: String, _ records: [DownloadRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title, count: records.count)
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider().padding(.leading, 70) }
                    DownloadTaskRow(store: store, record: record)
                }
            }.card(padding: 0)
        }
    }
}

private struct DownloadTaskRow: View {
    let store: AppStore
    let record: DownloadRecord
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(path: record.applicationID, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(record.applicationName).font(.headline).lineLimit(1)
                    if !record.targetVersion.isEmpty { Text(record.targetVersion).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    StatusBadge(text: label, symbol: symbol, tone: tone)
                }
                if record.state.active {
                    if record.expected > 0 { ProgressView(value: Double(min(record.received, record.expected)), total: Double(record.expected)) }
                    else { ProgressView().progressViewStyle(.linear) }
                }
                HStack(spacing: 8) {
                    Text(bytes)
                    if record.resumedBytes > 0 { Text("· 已接续保留进度") }
                    if record.retries > 0 { Text("· 自动重试 \(record.retries)/3") }
                    Text("· \(record.updatedAt.relativeDescription)")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let issue = record.issue, record.state == .failed {
                    Text(failure(issue)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if record.state.canPause {
                    Button { store.downloadCenter.pause(record.id) } label: { Label("暂停", systemImage: "pause.fill") }
                        .accessibilityIdentifier("pause-download-\(record.id)")
                }
                if record.state == .paused {
                    Button { store.downloadCenter.resume(record.id) } label: { Label("继续", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("resume-download-\(record.id)")
                }
                if record.state.active {
                    Button(role: .destructive) { store.downloadCenter.cancel(record.id) } label: { Label("取消此下载", systemImage: "xmark") }
                        .labelStyle(.iconOnly).help("取消此下载")
                        .accessibilityIdentifier("cancel-download-\(record.id)")
                } else if [.failed, .cancelled, .interrupted].contains(record.state) {
                    Button("重新检测并下载…") { store.retryDownload(record) }
                        .disabled(store.operationBusy)
                        .accessibilityIdentifier("retry-download-\(record.id)")
                }
            }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var bytes: String {
        let received = ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file)
        return record.expected > 0 ? received + " / " + ByteCountFormatter.string(fromByteCount: record.expected, countStyle: .file) : received
    }
    private func failure(_ issue: DiagnosticIssue) -> String {
        let message: String
        switch issue.kind {
        case .offline, .connection, .timeout: message = "网络连接未恢复，请联网后重新检测并下载。"
        case .tls: message = "安全连接未通过，请检查网络或使用官方更新。"
        case .http: message = "服务器未能提供安装包，请稍后重新检测来源。"
        case .validationRejected, .invalidMetadata: message = "下载或完整性校验未通过，请重新检测来源或使用官方更新。"
        default: message = "下载未完成，请重新检测来源；需要排查时可导出诊断报告。"
        }
        return message + (issue.httpStatus.map { " HTTP \($0)" } ?? "")
    }
    private var label: String {
        switch record.state {
        case .queued: "准备下载"
        case .downloading: "下载中"
        case .paused: "已暂停"
        case .waitingForNetwork: "等待网络"
        case .retrying: "稍后自动重试"
        case .verifying: "正在校验"
        case .downloaded: "已下载，待应用验证"
        case .verified: "已校验"
        case .failed: "下载失败"
        case .cancelled: "已取消"
        case .interrupted: "已中断，需重新检测"
        }
    }
    private var symbol: String {
        switch record.state {
        case .queued, .downloading: "arrow.down"
        case .paused: "pause.fill"
        case .waitingForNetwork: "wifi.slash"
        case .retrying: "arrow.clockwise"
        case .verifying: "checkmark.shield"
        case .downloaded: "shippingbox"
        case .verified: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark"
        case .interrupted: "bolt.horizontal"
        }
    }
    private var tone: Tone {
        switch record.state {
        case .queued, .downloading, .verifying: .accent
        case .verified: .success
        case .failed: .danger
        case .waitingForNetwork, .retrying, .interrupted: .warning
        case .paused, .cancelled, .downloaded: .neutral
        }
    }
}
