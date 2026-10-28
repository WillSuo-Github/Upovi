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
        case .queued: return String(localized: "排队中")
        case .downloading: return downloadDetail(at: Date())
        case .verifying: return String(localized: "正在校验签名与完整性")
        case .awaitingConfirmation: return String(localized: "已验证，等待确认安装")
        case .waitingForAuthorization: return String(localized: "等待授权")
        case .installing: return String(localized: "正在安装")
        case .installed: return String(localized: "已完成")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已停止")
        }
    }

    /// Ignore old samples after a stall, cancellation or the transition to verification.
    func liveBytesPerSecond(at now: Date) -> Double {
        guard phase == .downloading, let sampleTime,
              now.timeIntervalSince(sampleTime) < 2, bytesPerSecond.isFinite else { return 0 }
        return max(0, bytesPerSecond)
    }

    func downloadDetail(at now: Date) -> String {
        guard received > 0 else { return String(localized: "正在连接…") }
        let bytes = expected > 0 ? "\(Self.megabytes(received)) / \(Self.megabytes(expected))" : Self.megabytes(received)
        let rate = liveBytesPerSecond(at: now)
        return rate > 0 && expected > received
            ? bytes + " · " + Self.remaining(Double(expected - received) / rate) : bytes
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let parts = rateComponents(bytesPerSecond)
        return parts.value + " " + parts.unit
    }

    static func rateComponents(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let rate = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        let megabytes = rate >= 1_000_000
        let number = (rate / (megabytes ? 1_000_000 : 1_000)).formatted(
            .number.locale(.interface).precision(.fractionLength(megabytes ? 1 : 0)))
        return (number, megabytes ? "MB/s" : "KB/s")
    }

    /// Sampling state is independent of UI publication, so suppressed progress callbacks are
    /// never counted twice in the total rate. Each new transfer starts with a fresh sample.
    struct Sample {
        var startedAt: Date
        var received: Int64 = 0
        var bytesPerSecond: Double = 0

        mutating func record(_ bytes: Int64, at now: Date) -> Bool {
            guard bytes >= received else {
                self = Sample(startedAt: now, received: bytes)
                return true
            }
            let elapsed = now.timeIntervalSince(startedAt)
            guard elapsed >= 0.5 else { return false }
            let rate = Double(bytes - received) / elapsed
            bytesPerSecond = bytesPerSecond == 0 || elapsed >= 2 ? rate : bytesPerSecond * 0.6 + rate * 0.4
            startedAt = now; received = bytes
            return true
        }
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        if seconds < 60 { return String(localized: "剩余 \(max(1, Int(seconds.rounded()))) 秒") }
        if seconds < 3600 { return String(localized: "剩余约 \(Int((seconds / 60).rounded())) 分钟") }
        return String(localized: "剩余约 \(Int((seconds / 3600).rounded())) 小时")
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: bytes >= 100_000_000 ? "%.0f MB" : "%.1f MB", Double(bytes) / 1_000_000)
    }
}
