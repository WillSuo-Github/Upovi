import SwiftUI

/// Quiet capsule progress: a flat tone fill that eases toward its value, with one faint
/// highlight passing over it while work is in progress.
struct FlowProgressBar: View {
    var value: Double
    var tone: Tone = .accent
    var active = true
    var indeterminate = false
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private var target: Double { min(1, max(0, value.isFinite ? value : 0)) }
    private var moving: Bool { active && !reduceMotion && (indeterminate || (shown > 0 && shown < 1)) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = indeterminate ? width * 0.25 : max(shown > 0 ? height : 0, width * shown)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    Capsule().fill(color)
                        .overlay { if moving && !indeterminate { highlight(time, width: fillWidth) } }
                        .clipShape(Capsule())
                        .frame(width: fillWidth)
                        .offset(x: indeterminate ? slide(time, width: width, fill: fillWidth) : 0)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .onAppear { shown = target }
        .onChange(of: target) { _, next in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { shown = next }
        }
        .animation(.easeInOut(duration: 0.25), value: tone)
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue(indeterminate ? "进行中" : "\(Int(target * 100))%")
    }

    private var color: Color {
        switch tone {
        case .success: .green.opacity(0.55)
        case .danger: .red
        case .warning: .orange
        case .neutral: .secondary.opacity(0.45)
        default: Theme.accent
        }
    }

    /// A low-contrast band drifting across the fill, so a slow transfer still reads as alive.
    private func highlight(_ time: TimeInterval, width: CGFloat) -> some View {
        let cycle = 2.4, progress = CGFloat(time.truncatingRemainder(dividingBy: cycle) / cycle)
        let band = max(40, width * 0.4)
        return LinearGradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            .frame(width: band)
            .offset(x: -band + progress * (width + band))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slide(_ time: TimeInterval, width: CGFloat, fill: CGFloat) -> CGFloat {
        CGFloat((sin(time * 2) + 1) / 2) * (width - fill)
    }
}

#Preview {
    VStack(spacing: 18) {
        FlowProgressBar(value: 0.42)
        FlowProgressBar(value: 0.8, height: 6)
        FlowProgressBar(value: 0.3, indeterminate: true)
        FlowProgressBar(value: 1, tone: .success, active: false)
        FlowProgressBar(value: 0.6, tone: .danger, active: false)
    }
    .padding(30).frame(width: 420)
}
