import SwiftUI
import AppKit
import UpoviCore

/// Installation receipts with rollback, batch runs and recent checks.
struct InstallationHistoryView: View {
    @Bindable var store: AppStore
    @State private var tab = Tab.installations

    enum Tab: String, CaseIterable, Identifiable {
        case installations = "安装与恢复", batches = "批量任务", checks = "检查记录"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installations: String(localized: "安装与恢复"); case .batches: String(localized: "批量任务"); case .checks: String(localized: "检查记录")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "历史与恢复"), subtitle: String(localized: "Upovi 安装更新时会保留旧版本，可在这里恢复或清理保留副本。")) {
                    Picker("类别", selection: $tab) { ForEach(Tab.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }.entrance(0)
                if tab == .installations { summary.entrance(1) }
                Group {
                    switch tab {
                    case .installations: installations
                    case .batches: BatchHistoryList(store: store)
                    case .checks: checks
                    }
                }.entrance(2)
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 72)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .navigationTitle("历史与恢复")
        .task { await store.refreshInstallations() }
    }

    private var summary: some View {
        let retained = store.installationReceipts.filter { $0.retainedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
        let bytes = retained.compactMap { store.backupSizes[$0.id] }.reduce(0, +)
        return HStack(spacing: 12) {
            StatTile(value: store.installationReceipts.count.formatted(), label: String(localized: "安装记录"), symbol: "shippingbox")
            StatTile(value: retained.count.formatted(), label: String(localized: "可恢复的旧版本"), symbol: "clock.arrow.circlepath", tone: .success)
            StatTile(value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), label: String(localized: "保留副本占用"), symbol: "internaldrive", tone: .warning)
        }
    }

    @ViewBuilder private var installations: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: String(localized: "安装记录"), count: store.installationReceipts.count)
                if store.installationReceipts.isEmpty {
                    emptyCard(String(localized: "尚无安装记录"), symbol: "shippingbox", message: String(localized: "通过 Upovi 下载并验证的更新安装后会出现在这里。"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.installationReceipts.enumerated()), id: \.element.id) { index, receipt in
                            if index > 0 { Divider().padding(.leading, 66) }
                            ReceiptRow(store: store, receipt: receipt)
                        }
                    }.card(padding: 0)
                }
            }
            if !store.administrator.attempts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: String(localized: "管理员安装"), count: store.administrator.attempts.count)
                    Text("只恢复主应用，安装脚本和其他系统变更不会回滚。取消授权的尝试可能没有生成系统备份。")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(store.administrator.attempts.enumerated()), id: \.element.id) { index, attempt in
                            if index > 0 { Divider().padding(.leading, 66) }
                            AdministratorBackupRow(store: store, attempt: attempt)
                        }
                    }.card(padding: 0)
                }
            }
        }
    }

    @ViewBuilder private var checks: some View {
        if store.checkHistory.isEmpty {
            emptyCard(String(localized: "尚无检查记录"), symbol: "magnifyingglass", message: String(localized: "每次完成来源检查后都会记录检查数量与结果。"))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.checkHistory.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.display()).font(.callout.weight(.medium))
                            Text("\(entry.applications) 个应用").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(text: String(localized: "\(entry.updates) 个更新"), symbol: "arrow.down.circle", tone: entry.updates > 0 ? .accent : .neutral)
                        if entry.failed > 0 { StatusBadge(text: String(localized: "\(entry.failed) 项未完整检查"), symbol: "exclamationmark.triangle", tone: .warning) }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
            }.card(padding: 0)
        }
    }

    private func emptyCard(_ title: String, symbol: String, message: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }.card(padding: 18)
    }
}

private struct ReceiptRow: View {
    let store: AppStore
    let receipt: InstallationReceipt

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(path: receipt.application.path, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(receipt.application.name).font(.headline)
                    StatusBadge(text: stateLabel, symbol: stateSymbol, tone: stateTone)
                }
                VersionTransition(from: receipt.application.version, to: receipt.newVersion, tone: .neutral, font: .caption)
                HStack(spacing: 6) {
                    Text(receipt.date.display())
                    if let bytes = store.backupSizes[receipt.id] { Text("· 备份 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let path = receipt.retainedPath ?? ([.prepared, .backedUp, .failed].contains(receipt.state) ? receipt.backupPath : nil),
               FileManager.default.fileExists(atPath: path) {
                HStack(spacing: 8) {
                    if receipt.state != .restored {
                        Button("恢复旧版本…") { store.restoreConfirmation = receipt }.disabled(store.operationBusy)
                    }
                    Menu {
                        Button("在 Finder 中查看副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        if receipt.retainedPath != nil {
                            Divider()
                            Button("清理备份…", role: .destructive) { store.backupDeletionConfirmation = receipt }.disabled(store.operationBusy)
                                .accessibilityIdentifier("cleanup-backup-\(receipt.id)")
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }.controlSize(.small)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var stateLabel: String {
        switch receipt.state {
        case .prepared: String(localized: "安装未完成，请检查恢复备份")
        case .backedUp: String(localized: "安装中断，旧版本已保留")
        case .installed: String(localized: "已安装，可恢复")
        case .restored: String(localized: "旧版本已恢复")
        case .failed: String(localized: "安装未完成")
        case .backupDiscarded: String(localized: "保留副本已清理")
        }
    }
    private var stateSymbol: String {
        switch receipt.state {
        case .installed: "checkmark.circle.fill"
        case .restored: "arrow.uturn.backward.circle"
        case .prepared, .backedUp, .failed: "exclamationmark.triangle.fill"
        case .backupDiscarded: "trash"
        }
    }
    private var stateTone: Tone {
        switch receipt.state {
        case .installed: .success
        case .restored: .accent
        case .prepared, .backedUp, .failed: .warning
        case .backupDiscarded: .neutral
        }
    }
}

struct AdministratorBackupRow: View {
    let store: AppStore
    let attempt: AdministratorInstallAttempt

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(path: attempt.plan.application.path, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(attempt.plan.application.name).font(.headline)
                    StatusBadge(text: String(localized: "管理员"), symbol: "lock.fill")
                }
                VersionTransition(from: attempt.plan.application.version, to: attempt.plan.version, tone: .neutral, font: .caption)
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text(attempt.plan.application.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                if let bytes = attempt.backupBytes {
                    Text("保留数据占用（估算）：\(attempt.backupBytesIsLowerBound == true ? "至少 " : "")\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("核对记录…") { store.manageAdministratorBackup(attempt, cleanup: false) }.disabled(store.operationBusy)
                    .accessibilityIdentifier("inspect-admin-backup-\(attempt.id)")
                if AdministratorBackupCleaner.canRestore(attempt.state) {
                    Button("恢复主应用…") { store.administratorRestoreConfirmation = attempt }.disabled(store.operationBusy)
                }
                if ["installed", "restored"].contains(attempt.state) || (attempt.state == "backupDiscarded" && attempt.cleanupComplete == false) {
                    Button("清理…", role: .destructive) { store.administratorCleanupConfirmation = attempt }.disabled(store.operationBusy)
                        .accessibilityIdentifier("cleanup-admin-backup-\(attempt.id)")
                }
            }.controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var status: String {
        switch attempt.state {
        case "installed": String(localized: "安装完成，受保护的主应用备份已保留")
        case "restored": String(localized: "主应用已恢复，其他系统改动未回滚")
        case "backupDiscarded": attempt.cleanupComplete == true ? String(localized: "保留数据已清理，恢复已停用") : String(localized: "清理未完成，恢复已停用；可继续清理残留")
        case "cleanupPending": String(localized: "清理状态尚未确认，请先核对管理员记录")
        case "awaitingAuthorization": String(localized: "授权或安装可能中断，请检查恢复选项")
        default: String(localized: "安装未完成或授权已取消；恢复时会核对系统备份")
        }
    }
}

private struct BatchHistoryList: View {
    let store: AppStore

    var body: some View {
        if store.batchHistory.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.down.right").font(.title2).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("尚无批量任务").font(.headline)
                    Text("使用“全部更新”后，每一批的逐项结果会保存在这里，未完成项可以重新检测后恢复。").font(.callout).foregroundStyle(.secondary)
                }
            }.card(padding: 18)
        } else {
            VStack(spacing: 12) {
                ForEach(store.batchHistory) { record in BatchCard(store: store, record: record) }
            }
        }
    }
}

private struct BatchCard: View {
    let store: AppStore
    let record: BulkUpdateRecord
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var expanded = false

    var body: some View {
        let done = record.entries.filter { $0.phase == .installed || $0.phase == .current }.count
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.forward").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? (layoutDirection == .rightToLeft ? -90 : 90) : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.startedAt.display()).font(.headline)
                        Text("完成 \(done)/\(record.entries.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Gauge(value: Double(done), in: 0...Double(max(1, record.entries.count))) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity).tint(record.retryIDs.isEmpty ? Color.green : Color.orange).scaleEffect(0.6).frame(width: 34, height: 34)
                    StatusBadge(text: record.finishedAt == nil ? String(localized: "未完成") : String(localized: "已结束"), tone: record.finishedAt == nil ? .warning : .neutral)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.entries, id: \.item.id) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(entry.phase)).foregroundStyle(tone(entry.phase).color).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.application.name + " → " + entry.item.candidate.version).font(.callout)
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    if !record.retryIDs.isEmpty {
                        Button("重新检测并恢复未完成项") { store.retryBatch(record) }
                            .buttonStyle(.borderedProminent).disabled(store.operationBusy).padding(.top, 4)
                    }
                }.padding(.leading, 30)
            }
        }.card(padding: 14)
    }

    private func symbol(_ phase: BulkUpdateRecord.Phase) -> String {
        switch phase {
        case .installed, .current: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "minus.circle"
        case .manual: "arrow.up.forward.app"
        case .interrupted: "bolt.horizontal"
        case .pending, .preparing, .installing: "circle.dashed"
        }
    }
    private func tone(_ phase: BulkUpdateRecord.Phase) -> Tone {
        switch phase {
        case .installed, .current: .success
        case .failed: .danger
        case .interrupted: .warning
        default: .neutral
        }
    }
}
