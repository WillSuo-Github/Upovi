import Foundation

public struct BulkUpdateRecord: Identifiable, Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case pending, preparing, installing, installed, current, failed, cancelled, manual, interrupted }
    public struct Entry: Codable, Sendable {
        public let item: BulkUpdateItem
        public var phase: Phase
        public var detail: String
    }
    public let id: UUID
    public let startedAt: Date
    public var finishedAt: Date?
    public var entries: [Entry]
    public init(items: [BulkUpdateItem]) {
        id = UUID(); startedAt = Date()
        entries = items.map {
            var summary = $0.candidate
            summary.releaseNotes = nil; summary.download = nil
            let item = BulkUpdateItem(application: $0.application, candidate: summary, manualReason: $0.manualReason)
            return .init(item: item, phase: $0.canInstall ? .pending : .manual, detail: $0.manualReason ?? String(localized: "等待处理"))
        }
    }
    public var retryIDs: Set<String> {
        Set(entries.filter { [.pending, .preparing, .installing, .failed, .cancelled, .interrupted].contains($0.phase) }.map { $0.item.id })
    }
    public mutating func recoverInterrupted() {
        guard finishedAt == nil else { return }
        for i in entries.indices where [.pending, .preparing, .installing].contains(entries[i].phase) {
            entries[i].phase = .interrupted
            entries[i].detail = String(localized: "上次任务中断；恢复前将重新检测，不会自动安装")
        }
    }
    public mutating func update(_ id: String, phase: Phase, detail: String) {
        guard let i = entries.firstIndex(where: { $0.item.id == id }) else { return }
        entries[i].phase = phase; entries[i].detail = String(detail.prefix(2000))
    }
}
