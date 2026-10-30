import SwiftUI
import UpoviCore

extension ToolSource {
    var scopeDescription: String {
        switch self {
        case .homebrew: String(localized: "Homebrew 本身、软件索引与 Formula 命令行工具；图形应用仍使用原有更新流程。")
        case .npm: String(localized: "当前 npm 环境中全局安装的命令行工具，不修改项目依赖。")
        case .pnpm: String(localized: "当前 pnpm 环境中全局安装的命令行工具。")
        case .uv: String(localized: "通过 uv tool 安装的独立 Python 工具。")
        case .pipx: String(localized: "通过 pipx 安装的独立 Python 工具及其环境。")
        case .cargo: String(localized: "通过 Cargo 安装的二进制工具；需要已安装 cargo-update。")
        case .rustup: String(localized: "通过 rustup 安装的 stable、beta、nightly 工具链；保留固定版本。")
        }
    }
}

struct ToolSourcesSettings: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section {
                Text("打开开关后，此来源会参与检查和“全部更新”。打开开关只检查，不会立即安装更新。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("固定版本、自定义版本约束以及由其他运行时维护的软件会保留原有设置。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新检测工具") { store.rediscoverToolSources() }.disabled(store.installationBusy)
            } header: { Text("全局工具更新") }
            ForEach(ToolSource.allCases) { source in
                Section {
                    Toggle(source.title, isOn: Binding(get: { store.enabledToolSources.contains(source) }, set: { store.setToolSource(source, enabled: $0) }))
                        .disabled(store.installationBusy || (store.toolLocations[source] == nil && !store.enabledToolSources.contains(source)))
                        .accessibilityIdentifier("tool-source-" + source.rawValue)
                    Text(source.scopeDescription).font(.caption).foregroundStyle(.secondary)
                    if let location = store.toolLocations[source] {
                        Text(location.path).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    } else {
                        Text(source == .cargo ? "未检测到 Cargo 和 cargo-update；不会替你安装。" : "未检测到此包管理器；不会替你安装。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.toolCheckErrors[source], store.enabledToolSources.contains(source) {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            Section {
                Text("更新由原有包管理器执行，可能运行安装脚本。只管理全局工具，不修改项目文件、系统自带的软件或包管理器之外的二进制文件。更新记录可在“历史与恢复”查看，不提供 Upovi 应用备份回滚。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct ToolSourcesSection: View {
    @Bindable var store: AppStore
    private var sources: [ToolSource] { store.bulkSummaryVisible ? store.toolBatchSources : store.availableToolSources }
    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("全局工具").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if store.toolChecking { ProgressView().controlSize(.small) }
                    else if !store.bulkUpdating {
                        Button("检查工具更新") { store.refreshToolSources() }.disabled(store.operationBusy)
                            .buttonStyle(PillButtonStyle()).accessibilityIdentifier("check-tool-sources")
                    }
                }
                VStack(spacing: 0) {
                    ForEach(sources, id: \.self) { source in
                        if source.id != sources.first?.id { Divider().padding(.leading, 60) }
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "terminal.fill").font(.title2).foregroundStyle(Theme.accent).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title).font(.system(size: 14, weight: .semibold))
                                Text(detail(source)).font(.caption).foregroundStyle(store.toolCheckErrors[source] == nil ? Color.secondary : Color.orange)
                                    .lineLimit(3).help(detail(source))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if store.toolRunningSource == source { ProgressView().controlSize(.small) }
                            else {
                                Button("更新此来源") { store.reviewToolUpdates([source]) }
                                    .buttonStyle(PillButtonStyle()).disabled(store.operationBusy || store.toolChecking)
                                    .accessibilityIdentifier("update-tool-source-" + source.rawValue)
                            }
                        }.padding(16).accessibilityIdentifier("tool-source-row-" + source.rawValue)
                    }
                }.modifier(UpdatesSurface())
                Text("全局工具按来源依次更新。Homebrew 也会刷新自身和软件索引；正在执行的工具更新会完成后再停止后续任务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func detail(_ source: ToolSource) -> String {
        if store.toolRunningSource == source { return String(localized: "包管理器正在更新并核对结果…") }
        if let result = store.toolOutcomes[source], store.bulkSummaryVisible { return result.detail }
        if let error = store.toolCheckErrors[source] { return error }
        if let result = store.toolSnapshots[source] {
            let summary = String(localized: "已检查 \(result.installed.count) 个全局工具 · \(result.updates.count) 个有更新")
            let held = result.held.isEmpty ? "" : " · " + String(localized: "\(result.held.count) 个按原配置保留")
            return summary + held + (result.updates.isEmpty ? "" : "\n" + result.updates.prefix(4).map { $0.name + " " + $0.installed + " → " + $0.available }.joined(separator: " · "))
        }
        return store.toolChecking ? String(localized: "正在检查全局工具…") : String(localized: "尚未检查全局工具")
    }
}

struct ToolHistoryView: View {
    let store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全局工具更新记录").font(.headline)
            Text("由原有包管理器执行，不提供 Upovi 应用回滚。中断的更新需重新检查。")
                .font(.caption).foregroundStyle(.secondary)
            if store.toolHistory.isEmpty { Text("尚无全局工具更新记录").foregroundStyle(.secondary) }
            ForEach(store.toolHistory) { record in
                DisclosureGroup {
                    Text(record.detail).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack {
                        Text(record.source.title)
                        Spacer()
                        Text(state(record.state)).foregroundStyle(record.state == .failed ? Color.orange : Color.secondary)
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }.font(.callout)
                }.padding(12).card(padding: 0)
            }
        }
    }
    private func state(_ state: ToolUpdateRecord.State) -> String {
        switch state {
        case .running: String(localized: "正在更新…")
        case .succeeded: String(localized: "已完成")
        case .failed: String(localized: "失败")
        case .interrupted: String(localized: "已中断")
        }
    }
}
