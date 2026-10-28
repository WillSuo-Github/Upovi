import SwiftUI

/// Flat capsule progress with eased value changes. Only unknown-length downloads
/// need a continuously moving indicator.
struct FlowProgressBar: View {
    var value: Double
    var tone: Tone = .accent
    var active = true
    var indeterminate = false
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private var target: Double { min(1, max(0, value.isFinite ? value : 0)) }
    private var moving: Bool { active && !reduceMotion && indeterminate }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = indeterminate ? width * 0.25 : max(shown > 0 ? height : 0, width * shown)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    Capsule().fill(color)
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
        .accessibilityValue(indeterminate ? String(localized: "进行中") : target.formatted(.percent.precision(.fractionLength(0))))
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
