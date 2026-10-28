import SwiftUI
import AppKit

/// The selected design groups speed, progress and remaining time in one trailing column.
struct DownloadRate: View {
    let transfers: [TransferProgress]
    var total = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let rate = transfers.reduce(0) { $0 + $1.liveBytesPerSecond(at: context.date) }
            VStack(alignment: .leading, spacing: 4) {
                if total {
                    Text("总下载速度").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Text(TransferProgress.rate(rate))
                    .font(.system(size: total ? 20 : 16, weight: .medium))
                    .monospacedDigit().foregroundStyle(.primary).lineLimit(1).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(total ? Text("总下载速度") : Text("下载速度"))
            .accessibilityValue(TransferProgress.rate(rate))
        }
        .accessibilityIdentifier(total ? "total-download-rate" : "application-download-rate")
    }
}

/// This column has a fixed footprint; starting a transfer replaces the row's action area.
struct TransferMeter: View {
    let transfer: TransferProgress
    var detail: String? = nil
    var cancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if transfer.phase == .downloading {
                    DownloadRate(transfers: [transfer])
                } else {
                    Text(transfer.label).font(.callout.weight(.medium))
                        .foregroundStyle(transfer.phase == .installed ? Color.green : .secondary)
                        .lineLimit(1).help(transfer.label)
                }
                Spacer(minLength: 0)
                if let cancel, transfer.canCancel {
                    Button(action: cancel) { Image(systemName: "xmark").font(.caption).frame(width: 18, height: 18) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("取消下载")
                }
            }
            .frame(height: 20).padding(.trailing, 24)
            HStack(spacing: 10) {
                FlowProgressBar(value: transfer.fraction, tone: tone, active: transfer.isActive,
                                indeterminate: transfer.indeterminate, height: 5)
                Text(transfer.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(height: 5)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let label = detail ?? (transfer.phase == .downloading ? transfer.downloadDetail(at: context.date)
                    : transfer.received > 0 ? TransferProgress.megabytes(transfer.received) : "")
                Text(label).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(label).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 17)
        }
        .frame(height: 52)
        .accessibilityIdentifier("transfer-meter")
    }

    private var tone: Tone {
        switch transfer.phase {
        case .installed: .success
        case .failed: .warning
        case .cancelled, .queued: .neutral
        default: .accent
        }
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
            .background(UpdatesPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
