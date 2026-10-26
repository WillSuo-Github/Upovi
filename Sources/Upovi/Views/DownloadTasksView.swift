import SwiftUI
import UpoviCore

struct DownloadTasksView: View {
    let store: AppStore
    private var records: [DownloadRecord] {
        store.downloadCenter.records.filter { store.search.isEmpty || $0.applicationName.localizedCaseInsensitiveContains(store.search) || $0.bundleID.localizedCaseInsensitiveContains(store.search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("下载任务").font(.largeTitle.bold())
                Text("暂停保留进度；断网后等待重连，临时网络错误最多自动重试 3 次。安装仍按原有确认流程执行。")
                    .foregroundStyle(.secondary)
                if store.downloadCenter.historySaveFailed { Text("下载记录未能保存；当前任务仍可操作，退出后可能缺少记录。").foregroundStyle(.orange) }
                if records.isEmpty { ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.circle", description: Text("从应用详情或全部更新开始下载，任务会显示在这里。")) }
                ForEach(records) { record in
                    DownloadTaskRow(store: store, record: record)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.task { store.downloadCenter.start() }
    }
}

private struct DownloadTaskRow: View {
    let store: AppStore
    let record: DownloadRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.applicationName).font(.headline)
                if !record.targetVersion.isEmpty { Text(record.targetVersion).foregroundStyle(.secondary) }
                Spacer()
                Text(label).font(.callout)
            }
            if record.state.active {
                if record.expected > 0 { ProgressView(value: Double(min(record.received, record.expected)), total: Double(record.expected)) }
                else { ProgressView().controlSize(.small) }
            }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file))
                if record.expected > 0 { Text("/ " + ByteCountFormatter.string(fromByteCount: record.expected, countStyle: .file)) }
                if record.resumedBytes > 0 { Text("已接续保留进度") }
                if record.retries > 0 { Text("自动重试 \(record.retries)/3") }
            }.font(.caption).foregroundStyle(.secondary)
            if let issue = record.issue, record.state == .failed {
                Text(failure(issue))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if record.state.canPause {
                    Button("暂停") { store.downloadCenter.pause(record.id) }.accessibilityIdentifier("pause-download-\(record.id)")
                }
                if record.state == .paused {
                    Button("继续") { store.downloadCenter.resume(record.id) }.accessibilityIdentifier("resume-download-\(record.id)")
                }
                if record.state.active {
                    Button("取消此下载", role: .destructive) { store.downloadCenter.cancel(record.id) }.accessibilityIdentifier("cancel-download-\(record.id)")
                } else if [.failed, .cancelled, .interrupted].contains(record.state) {
                    Button("重新检测并下载…") { store.retryDownload(record) }
                        .disabled(store.installationBusy || store.refreshing || store.checking || store.scanning)
                        .accessibilityIdentifier("retry-download-\(record.id)")
                }
            }
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
        case .waitingForNetwork: "等待网络，联网后继续"
        case .retrying: "稍后自动重试"
        case .verifying: "正在校验完整性"
        case .verified: "下载已校验"
        case .failed: "下载失败"
        case .cancelled: "已取消"
        case .interrupted: "上次任务已中断，需重新检测"
        }
    }
}
