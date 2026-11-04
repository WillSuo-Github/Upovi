import SwiftUI
import UniformTypeIdentifiers
import UpoviCore

private struct DiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        return wrapper
    }
}

struct DiagnosticsView: View {
    let snapshot: DiagnosticSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var includeIdentifiers = false
    @State private var exporting = false
    @State private var preparing = false
    @State private var includeLogs = true
    @State private var archive: Data?
    @State private var exportTask: Task<Void, Never>?
    @State private var status = ""
    @State private var showLogPreview = false
    @State private var logPreview = ""
    @State private var loadingLogs = false
    private var report: Data? { try? snapshot.report(includingApplicationIdentifiers: includeIdentifiers) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "stethoscope").font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("诊断与日志").font(.title3.weight(.semibold))
                    Text("诊断包包含当前检查摘要和近期运行日志，可追查检测、下载、授权与安装过程。摘要默认隐藏软件标识；日志包含版本、操作耗时和经过过滤的错误详情。密码、凭据和完整路径不会主动记录，导出前请确认内容。文件仅保存到你选择的位置，不会自动上传。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("包含应用标识与版本（会暴露软件清单）", isOn: $includeIdentifiers)
                .accessibilityIdentifier("diagnostics-identifiers-toggle")
                .disabled(preparing)
            Toggle("包含近期运行日志（推荐用于排查问题）", isOn: $includeLogs)
                .accessibilityIdentifier("diagnostics-logs-toggle")
                .disabled(preparing)
            HStack {
                Text(showLogPreview ? "近期运行日志" : "当前检查摘要").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showLogPreview ? "查看检查摘要" : "预览近期运行日志") { showLogPreview.toggle() }
                    .accessibilityIdentifier("diagnostics-switch-preview")
            }
            ScrollView {
                Text(showLogPreview ? (loadingLogs ? String(localized: "正在读取日志…") : logPreview) : report.map { String(decoding: $0, as: UTF8.self) } ?? String(localized: "报告生成失败"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .accessibilityIdentifier("diagnostics-preview")
                    .id(includeIdentifiers)
            }.frame(minHeight: 250).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !status.isEmpty { Text(status).font(.caption).accessibilityIdentifier("diagnostics-export-status") }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(preparing ? "正在准备诊断包…" : "导出诊断包…") { prepareArchive() }.disabled(report == nil || preparing).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("save-diagnostics-report")
            }
        }.padding(24).frame(width: 700, height: 620)
        .onDisappear { exportTask?.cancel() }
        .task(id: showLogPreview) {
            guard showLogPreview else { return }
            loadingLogs = true
            defer { loadingLogs = false }
            do {
                let value = try await Task.detached(priority: .utility) {
                    let text = try UpoviLogManager.shared.exportSnapshot()
                    let bytes = Data(text.utf8)
                    if bytes.count > 128 * 1024 {
                        return String(localized: "仅预览最近 128 KiB；完整日志包含在诊断包中。") + "\n\n" + String(decoding: bytes.suffix(128 * 1024), as: UTF8.self)
                    }
                    return text
                }.value
                if !Task.isCancelled { logPreview = value }
            } catch { logPreview = String(localized: "日志读取失败，无法预览。") }
        }
        .fileExporter(isPresented: $exporting, document: DiagnosticDocument(data: archive ?? Data()), contentType: .zip,
                      defaultFilename: "Upovi-Diagnostics-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))) { result in
            switch result {
            case .success(let url):
                do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                catch { UpoviLog.diagnostics.warning("event=export.permissionsUnchanged \(UpoviDiagnosticContext.errorSummary(error))") }
                status = String(localized: "诊断包已保存，未上传。")
                UpoviLog.diagnostics.info("event=export.saved")
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    status = String(localized: "诊断包保存失败，请重新选择保存位置。")
                    UpoviLog.diagnostics.error("event=export.saveFailed \(UpoviDiagnosticContext.errorSummary(error))")
                } else { UpoviLog.diagnostics.info("event=export.cancelled") }

            }
        }
    }
    private func prepareArchive() {
        guard let report, !preparing else { return }
        preparing = true; status = ""
        let includesLogs = includeLogs
        exportTask = Task {
            defer { preparing = false }
            do {
                archive = try await DiagnosticArchive.prepare(report: report, includeLogs: includesLogs,
                    environment: .init(version: AppMetadata.version, build: AppMetadata.build,
                        sourceRevision: Bundle.main.object(forInfoDictionaryKey: "UpoviSourceRevision") as? String ?? "development"))
                guard !Task.isCancelled else { return }
                exporting = true
            } catch {
                if !UpoviDiagnosticContext.isCancellation(error) {
                    status = String(localized: "诊断包生成失败，未导出不完整日志。请检查日志目录的可读性和可用空间后重试。")
                }
            }
        }
    }

}
