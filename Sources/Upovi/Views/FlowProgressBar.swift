import SwiftUI

/// Animated capsule progress: a springy gradient fill with drifting stripes, a sweeping sheen
/// and a glowing leading edge while active, plus a flash when it completes.
struct FlowProgressBar: View {
    var value: Double
    var tone: Tone = .accent
    var active = true
    var indeterminate = false
    var height: CGFloat = 6
    /// Light treatment for bars placed on the cobalt hero gradient.
    var onAccent = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    @State private var flash: Double = 0

    private var target: Double { min(1, max(0, value.isFinite ? value : 0)) }
    private var moving: Bool { active && !reduceMotion && (indeterminate || (shown > 0 && shown < 1)) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = indeterminate ? width * 0.3 : max(shown > 0 ? height : 0, width * shown)
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                TimelineView(.animation(paused: !moving)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    fill(width: fillWidth, time: time)
                        .offset(x: indeterminate ? slide(time, width: width, fill: fillWidth) : 0)
                }
                .clipShape(indeterminate ? AnyShape(Capsule()) : AnyShape(Rectangle().inset(by: -height * 3)))
            }
        }
        .frame(height: height)
        .onAppear { shown = target }
        .onChange(of: target) { _, next in
            withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.55, dampingFraction: 0.78)) { shown = next }
        }
        .onChange(of: tone) { _, next in
            guard next == .success, !reduceMotion else { return }
            flash = 0.9
            withAnimation(.easeOut(duration: 0.7)) { flash = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue(indeterminate ? "进行中" : "\(Int(target * 100))%")
    }

    private var track: AnyShapeStyle {
        onAccent ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.quaternary)
    }

    private var colors: [Color] {
        // The hero card already carries the tone; a white fill stays legible on every card color.
        if onAccent { return [.white.opacity(0.75), .white] }
        switch tone {
        case .success: return [Color(red: 0.12, green: 0.70, blue: 0.48), Color(red: 0.30, green: 0.86, blue: 0.56)]
        case .danger: return [Color(red: 0.92, green: 0.26, blue: 0.30), Color(red: 1.00, green: 0.52, blue: 0.30)]
        case .neutral: return [Color.secondary.opacity(0.5), Color.secondary.opacity(0.7)]
        default: return [Theme.cobalt, Theme.sky, Color(red: 0.42, green: 0.86, blue: 1.00)]
        }
    }

    private var glow: Color { onAccent ? .white : colors.last ?? Theme.sky }

    @ViewBuilder private func fill(width: CGFloat, time: TimeInterval) -> some View {
        let animated = moving
        Capsule()
            .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .overlay { if animated { stripes(time).clipShape(Capsule()) } }
            .overlay { if animated { sheen(time, width: width).clipShape(Capsule()) } }
            .overlay { Capsule().fill(.white).opacity(flash) }
            .overlay(alignment: .trailing) {
                if animated && !indeterminate {
                    Circle().fill(.white).frame(width: height * 1.1, height: height * 1.1)
                        .blur(radius: height * 0.35)
                        .opacity(0.65 + 0.35 * sin(time * 6))
                }
            }
            .frame(width: width)
            .shadow(color: glow.opacity(animated ? 0.55 : 0.2), radius: animated ? height * 1.2 : height * 0.4)
    }

    /// Diagonal barber-pole stripes drifting toward the leading edge.
    private func stripes(_ time: TimeInterval) -> some View {
        Canvas { context, size in
            let spacing = max(10, height * 2.2), slant = size.height
            let phase = CGFloat((time * 28).truncatingRemainder(dividingBy: Double(spacing)))
            var path = Path()
            var x = -spacing * 2 + phase
            while x < size.width + spacing {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + slant, y: 0))
                path.addLine(to: CGPoint(x: x + slant + spacing / 2, y: 0))
                path.addLine(to: CGPoint(x: x + spacing / 2, y: size.height))
                path.closeSubpath()
                x += spacing
            }
            context.fill(path, with: .color(.white.opacity(onAccent ? 0.10 : 0.16)))
        }
    }

    /// A soft highlight that sweeps across the fill every 1.6 seconds.
    private func sheen(_ time: TimeInterval, width: CGFloat) -> some View {
        let cycle = 1.6, progress = CGFloat(time.truncatingRemainder(dividingBy: cycle) / cycle)
        let band = max(24, width * 0.35)
        return LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            .frame(width: band)
            .offset(x: -band + progress * (width + band))
            .frame(maxWidth: .infinity, alignment: .leading)
            .blendMode(.plusLighter)
    }

    private func slide(_ time: TimeInterval, width: CGFloat, fill: CGFloat) -> CGFloat {
        let position = (sin(time * 2.4) + 1) / 2
        return CGFloat(position) * (width - fill)
    }
}

#Preview {
    VStack(spacing: 18) {
        FlowProgressBar(value: 0.42)
        FlowProgressBar(value: 0.8, height: 10)
        FlowProgressBar(value: 0.3, indeterminate: true)
        FlowProgressBar(value: 1, tone: .success, active: false)
        FlowProgressBar(value: 0.6, tone: .danger, active: false)
    }
    .padding(30).frame(width: 420)
}
