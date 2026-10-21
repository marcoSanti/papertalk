// The app's shared look on macOS: metrics, glass cards, tinted buttons, section labels, status
// badges, a wrapping layout, the window background and per-name colours.

#if os(macOS)
import SwiftUI

// MARK: - Design tokens
//
// Shared metrics + small building blocks for the Liquid Glass look (macOS 26).
// Rule of thumb used across the app: glass is reserved for the *floating*
// layer (toolbars, filter bar, player, inspector cards over artwork, badges
// over thumbnails); scrolling content stays opaque/quiet so the glass has
// something to refract.
enum Theme {
    /// Corner radius of glass cards.
    static let cardRadius: CGFloat = 18
    /// Corner radius of grid tiles.
    static let tileRadius: CGFloat = 12
    /// Corner radius of small covers.
    static let thumbRadius: CGFloat = 8
    /// Typical paper page aspect ratio (US Letter / A4 ≈ 0.71–0.77).
    static let pageAspect: CGFloat = 0.75
}

// MARK: - Glass card

/// A rounded Liquid Glass panel used to group content (inspector sections,
/// floating bars). Pass `tint` to give the glass a faint colour cast.
struct GlassCard: ViewModifier {
    /// Corner radius.
    var radius: CGFloat = Theme.cardRadius
    /// Inner padding.
    var padding: CGFloat = 14
    /// A faint colour cast; nil for plain glass.
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// Wrap the view in a `GlassCard`.
    func glassCard(radius: CGFloat = Theme.cardRadius, padding: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, padding: padding, tint: tint))
    }
}

// MARK: - Tinted button

/// A sheet button in a colour of its own. `.glass` / `.glassProminent` ignore
/// `.tint` inside sheets (every button came out the same), so this paints a
/// plain capsule. Prominent: filled with `color`, white label; otherwise a
/// faint wash with the label in `color`.
struct TintedButtonStyle: ButtonStyle {
    /// The label colour, or the fill when prominent.
    var color: Color
    /// Filled with `color` and a white label, for the main action.
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.white : color)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(prominent ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.15))))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == TintedButtonStyle {
    /// `.buttonStyle(.tinted(.red))`.
    static func tinted(_ color: Color, prominent: Bool = false) -> TintedButtonStyle {
        TintedButtonStyle(color: color, prominent: prominent)
    }
}

// MARK: - Section label

/// Small all-caps heading used above grouped content.
struct SectionLabel: View {
    let title: String
    var systemImage: String? = nil
    /// Small text at the right end (e.g. a percentage).
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title.uppercased())
                .tracking(0.6)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Status badge

/// Glass capsule describing where a paper is in the pipeline.
struct StatusBadge: View {
    let paper: Paper
    /// Icon only, for small covers.
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if paper.isActive {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: PaperPresentation.statusIcon(paper))
            }
            if !compact { Text(PaperPresentation.statusText(paper)) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(color.opacity(0.22)), in: Capsule())
        .help(PaperPresentation.statusText(paper))
    }

    private var color: Color {
        switch paper.statusKind {
        case .running: return .appAccent
        case .done: return paper.read ? .secondary : .green
        case .error: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - Flow layout

/// Wraps children onto as many lines as needed (tag chips, author pills).
struct FlowLayout: Layout {
    /// Between items on a line.
    var spacing: CGFloat = 6
    /// Between lines.
    var lineSpacing: CGFloat = 6

    /// The height of every line once wrapped at the proposed width.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = measured(view, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    /// Place items left to right, wrapping at the edge.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = measured(view, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    /// A child's size, never wider than the line.
    private func measured(_ view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

// MARK: - Ambient window backdrop

/// Very soft colour wash behind the library so the floating glass (filter bar,
/// player, toolbar) has some light to bend. Adapts to light/dark.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.appAccent.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.indigo.opacity(scheme == .dark ? 0.14 : 0.06), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Stable colours

extension Color {
    /// A deterministic, pleasant colour derived from a string (author avatars,
    /// per-paper backdrop). Uses FNV-1a so it is stable across launches,
    /// unlike `String.hashValue`.
    static func stable(for key: String, saturation: Double = 0.55, brightness: Double = 0.85) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

#endif
