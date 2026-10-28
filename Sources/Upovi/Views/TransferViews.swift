import SwiftUI
import AppKit

/// The selected design groups speed, progress and remaining time in one trailing column.
struct DownloadRate: View {
    let transfers: [TransferProgress]
    var total = false
    /// Single-line variant for inline status rows.
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let rate = transfers.reduce(0) { $0 + $1.liveBytesPerSecond(at: context.date) }
            VStack(alignment: .leading, spacing: 4) {
                if total, !compact {
                    Text("总下载速度").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Text(TransferProgress.rate(rate))
                    .font(.system(size: compact ? 13 : total ? 20 : 16, weight: .medium))
                    .monospacedDigit().foregroundStyle(.primary).lineLimit(1).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(total ? Text("总下载速度") : Text("下载速度"))
            .accessibilityValue(TransferProgress.rate(rate))
        }
        .accessibilityIdentifier(total ? "total-download-rate" : "application-download-rate")
    }
}

/// App Store-style circular progress; a stop glyph in the centre cancels a cancellable transfer.
struct TransferRing: View {
    let transfer: TransferProgress
    var cancel: (() -> Void)? = nil
    private let size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch transfer.phase {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .cancelled:
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
            default:
                if let cancel, transfer.canCancel {
                    Button(action: cancel) { ring }.buttonStyle(.plain)
                        .help("取消下载").accessibilityLabel(Text("取消下载"))
                } else { ring }
            }
        }
        .font(.system(size: size - 2))
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: transfer.phase)
        .accessibilityValue(Text(transfer.fraction, format: .percent.precision(.fractionLength(0))))
        .accessibilityIdentifier("transfer-meter")
    }

    private var spinning: Bool { transfer.indeterminate || [.verifying, .installing].contains(transfer.phase) }

    private var ring: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            if spinning && !reduceMotion {
                TimelineView(.animation) { context in
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            } else {
                // Queued transfers show only the track; a minimum sliver would read as a glitch.
                Circle().trim(from: 0, to: transfer.phase == .queued ? 0 : max(0.02, transfer.fraction))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: transfer.fraction)
            }
            if cancel != nil, transfer.canCancel {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.accent).frame(width: 8, height: 8)
            }
        }
        .frame(width: size - 3, height: size - 3)
        .contentShape(Circle())
    }
}

/// Replaces a row's version line while a transfer runs: size, speed and time remaining in one line.
struct TransferStatusLine: View {
    let transfer: TransferProgress
    var detail: String? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let text = label(at: context.date)
            Text(text)
                .foregroundStyle(transfer.phase == .failed ? AnyShapeStyle(.orange)
                                 : transfer.phase == .installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .monospacedDigit().lineLimit(1).truncationMode(.middle).help(text)
        }
    }

    private func label(at date: Date) -> String {
        if let detail, transfer.phase == .failed { return detail }
        guard transfer.phase == .downloading else { return transfer.label }
        let rate = transfer.liveBytesPerSecond(at: date)
        guard transfer.received > 0, rate > 0 else { return transfer.downloadDetail(at: date) }
        let bytes = transfer.expected > 0
            ? "\(TransferProgress.megabytes(transfer.received)) / \(TransferProgress.megabytes(transfer.expected))"
            : TransferProgress.megabytes(transfer.received)
        var parts = [bytes, TransferProgress.rate(rate)]
        if transfer.expected > transfer.received {
            parts.append(TransferProgress.remaining(Double(transfer.expected - transfer.received) / rate))
        }
        return parts.joined(separator: " · ")
    }
}

struct ReleaseNotesControl: View {
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            Label(expanded ? "收起更新说明" : "更新说明", systemImage: expanded ? "chevron.up" : "text.alignleft")
                .font(.caption)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).fixedSize()
    }
}

/// One shared grouped surface, rather than a card for each application.
struct UpdatesSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background(UpdatesPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

enum UpdatesPalette {
    static let page = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    })
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.15, alpha: 1) : .white
    })
}
