import Foundation

/// Per-application download and installation progress shown on its row.
struct TransferProgress: Equatable {
    enum Phase: Equatable {
        case queued, downloading, verifying, awaitingConfirmation, waitingForAuthorization, installing, installed, failed, cancelled
    }
    var phase: Phase = .queued
    var received: Int64 = 0
    var expected: Int64 = 0
    /// Smoothed transfer rate of this application's download.
    var bytesPerSecond: Double = 0
    var sampleTime: Date?
    var sampleBytes: Int64 = 0
    /// Fraction kept when a transfer stops early, so a failed bar does not jump.
    private var settled: Double?

    init(phase: Phase = .queued) { self.phase = phase }

    var downloadFraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    /// Downloading fills most of the bar; verification and installation fill the rest.
    var fraction: Double {
        if let settled { return settled }
        switch phase {
        case .queued: return 0
        case .downloading: return (downloadFraction ?? 0) * 0.8
        case .verifying: return 0.84
        case .awaitingConfirmation: return 0.88
        case .waitingForAuthorization: return 0.9
        case .installing: return 0.95
        case .installed, .failed, .cancelled: return 1
        }
    }
    var isActive: Bool { [.downloading, .verifying, .waitingForAuthorization, .installing].contains(phase) }
    var isFinished: Bool { [.installed, .failed, .cancelled].contains(phase) }
    var indeterminate: Bool { phase == .downloading && downloadFraction == nil }
    var canCancel: Bool { [.queued, .downloading, .verifying].contains(phase) }

    mutating func finish(_ phase: Phase) {
        if phase != .installed { settled = max(fraction, 0.04) }
        self.phase = phase
    }

    var label: String {
        switch phase {
        case .queued: return "排队中"
        case .downloading:
            // The row's single percentage covers the whole update, so the status line shows bytes only.
            guard received > 0 else { return "正在连接…" }
            var parts = [expected > 0 ? "\(Self.megabytes(received)) / \(Self.megabytes(expected))" : Self.megabytes(received)]
            if bytesPerSecond > 0 {
                parts.append(Self.rate(bytesPerSecond))
                if expected > received { parts.append(Self.remaining(Double(expected - received) / bytesPerSecond)) }
            }
            return parts.joined(separator: " · ")
        case .verifying: return "正在校验签名与完整性"
        case .awaitingConfirmation: return "已验证，等待确认安装"
        case .waitingForAuthorization: return "等待授权"
        case .installing: return "正在安装"
        case .installed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1_000_000 ? String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
            : String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        if seconds < 60 { return "剩余 \(max(1, Int(seconds.rounded()))) 秒" }
        if seconds < 3600 { return "剩余约 \(Int((seconds / 60).rounded())) 分钟" }
        return "剩余约 \(Int((seconds / 3600).rounded())) 小时"
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: bytes >= 100_000_000 ? "%.0f MB" : "%.1f MB", Double(bytes) / 1_000_000)
    }
}
