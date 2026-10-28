import SwiftUI
import AppKit

/// Shared visual language: the cobalt gradient comes from the app icon; semantic tones stay consistent across pages.
enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.62, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.19, green: 0.40, blue: 0.90, alpha: 1)
    })
    static let sky = Color(red: 0.33, green: 0.64, blue: 0.98)
    static let cobalt = Color(red: 0.24, green: 0.33, blue: 0.86)
    static let brandGradient = LinearGradient(colors: [sky, cobalt], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static let cornerRadius: CGFloat = 14
}

enum Tone {
    case accent, success, warning, danger, community, neutral

    var color: Color {
        switch self {
        case .accent: Theme.accent
        case .success: .green
        case .warning: .orange
        case .danger: .red
        case .community: Color(red: 0.95, green: 0.62, blue: 0.18)
        case .neutral: .secondary
        }
    }
}

/// Compact status capsule used in tables, rows and inspectors.
struct StatusBadge: View {
    let text: String
    var symbol: String? = nil
    var tone: Tone = .neutral
    // Selected table rows use an accent background; switch to a neutral treatment to stay legible.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .background(prominence == .increased ? AnyShapeStyle(.white.opacity(0.22))
                    : tone == .neutral ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tone.color.opacity(0.14)), in: Capsule())
    }
}

/// Version text tinted by tone, falling back to the row's foreground on selected rows.
struct ToneText: View {
    let text: String
    let tone: Tone
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        Text(text).foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(tone.color))
    }
}

/// Hairline-bordered surface used for cards throughout the main window.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.08)) } ?? AnyShapeStyle(.background.secondary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(.separator.opacity(0.6)), lineWidth: 1)
            }
    }
}

extension View {
    func card(padding: CGFloat = 16, tint: Color? = nil) -> some View { modifier(CardBackground(padding: padding, tint: tint)) }

    /// Staggered fade/slide entrance for page sections.
    func entrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }
}

private struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                withAnimation(.spring(duration: 0.45).delay(Double(min(index, 8)) * 0.05)) { shown = true }
            }
    }
}

/// Application icon with a process-wide cache; NSWorkspace icon lookup is comparatively expensive in table rows.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    @MainActor private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.icon(for: path)).resizable().interpolation(.high).frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// "1.2 → 1.3" with the target emphasized.
struct VersionTransition: View {
    let from: String
    let to: String
    var tone: Tone = .accent
    var font: Font = .callout

    var body: some View {
        HStack(spacing: 6) {
            Text(from).foregroundStyle(.secondary)
            Image(systemName: "arrow.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            Text(to).fontWeight(.semibold).foregroundStyle(tone.color)
        }
        .font(font.monospacedDigit()).lineLimit(1)
    }
}

/// Large page title with optional subtitle and trailing accessory.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.display(26))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct SectionTitle: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if let count { Text(count.formatted()).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
            Spacer()
        }
    }
}

/// Small metric tile for summaries.
struct StatTile: View {
    let value: String
    let label: String
    var symbol: String
    var tone: Tone = .accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(tone.color)
                .frame(width: 36, height: 36).background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(Theme.display(20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.card(padding: 12)
    }
}

/// Gradient hero surface with soft light blobs; used for page summaries.
struct HeroBackground: View {
    var colors: [Color] = [Theme.sky, Theme.cobalt]
    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                Circle().fill(.white.opacity(0.16)).frame(width: proxy.size.height * 1.6)
                    .offset(x: proxy.size.width - proxy.size.height * 0.9, y: -proxy.size.height * 0.75).blur(radius: 2)
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1.5).frame(width: proxy.size.height * 1.1)
                    .offset(x: proxy.size.width - proxy.size.height * 0.45, y: proxy.size.height * 0.25)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A white-on-gradient button for hero surfaces.
struct HeroButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(prominent ? AnyShapeStyle(Theme.cobalt) : AnyShapeStyle(.white))
            .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(Capsule())
    }
}

/// App Store-style capsule action: accent text on a soft fill, or a solid accent fill when prominent.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14).frame(minWidth: 64, minHeight: 26)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accent))
            .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.fill.tertiary), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Uniform confirmation sheet for destructive or system-changing operations.
struct ConfirmationSheet: View {
    let symbol: String
    var tone: Tone = .accent
    let title: String
    let message: String
    var detail: String? = nil
    var path: String? = nil
    let confirmTitle: String
    var destructive = false
    var confirmIdentifier: String? = nil
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(tone.color)
                    .frame(width: 44, height: 44).background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    if let path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            Text(message).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Label(detail, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(role: destructive ? .destructive : nil, action: confirm) { Text(confirmTitle) }
                    .buttonStyle(.borderedProminent).tint(destructive ? .red : Theme.accent)
                    .accessibilityIdentifier(confirmIdentifier ?? "")
            }.padding(.top, 4)
        }.padding(24).frame(width: 480)
    }
}

extension Locale {
    /// Dates follow the user's language and region, matching the localized interface.
    static let interface = Locale.autoupdatingCurrent
}

extension Date {
    var relativeDescription: String { formatted(.relative(presentation: .named).locale(.interface)) }
    func display(date: Date.FormatStyle.DateStyle = .abbreviated, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(.interface))
    }
}
