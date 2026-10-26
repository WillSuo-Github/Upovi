import SwiftUI
import UniformTypeIdentifiers
import UpoviCore

private struct DiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DiagnosticsView: View {
    let snapshot: DiagnosticSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var includeIdentifiers = false
    @State private var exporting = false
    @State private var status = ""
    private var report: Data? { try? snapshot.report(includingApplicationIdentifiers: includeIdentifiers) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "stethoscope").font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("诊断报告").font(.title3.weight(.semibold))
                    Text("包含来源检查状态、失败阶段和错误代码。默认使用临时应用编号；不包含本机路径、设备名、IP、来源／下载链接、原始日志或凭据。报告只保存到你选择的位置，不会自动上传。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("包含应用标识与版本（会暴露软件清单）", isOn: $includeIdentifiers)
                .accessibilityIdentifier("diagnostics-identifiers-toggle")
            ScrollView {
                Text(report.map { String(decoding: $0, as: UTF8.self) } ?? "报告生成失败")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .accessibilityIdentifier("diagnostics-preview")
                    .id(includeIdentifiers)
            }.frame(minHeight: 250).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !status.isEmpty { Text(status).font(.caption).accessibilityIdentifier("diagnostics-export-status") }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存诊断报告…") { status = ""; exporting = true }.disabled(report == nil).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("save-diagnostics-report")
            }
        }.padding(24).frame(width: 650, height: 560)
        .fileExporter(isPresented: $exporting, document: DiagnosticDocument(data: report ?? Data()), contentType: .json,
                      defaultFilename: "Upovi-Diagnostics") { result in
            switch result {
            case .success: status = "诊断报告已保存，未上传。"
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { status = "诊断报告保存失败，请重新选择保存位置。" }
            }
        }
    }
}
