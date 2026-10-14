import SwiftUI

// MARK: - Design tokens
//
// Shared metrics + small building blocks for the Liquid Glass look (macOS 26).
// Rule of thumb used across the app: glass is reserved for the *floating*
// layer (toolbars, filter bar, player, inspector cards over artwork, badges
// over thumbnails); scrolling content stays opaque/quiet so the glass has
// something to refract.
enum Theme {
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 12
    static let thumbRadius: CGFloat = 8
    /// Typical paper page aspect ratio (US Letter / A4 ≈ 0.71–0.77).
    static let pageAspect: CGFloat = 0.75
}

// MARK: - Glass card

/// A rounded Liquid Glass panel used to group content (inspector sections,
/// floating bars). Pass `tint` to give the glass a faint colour cast.
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var padding: CGFloat = 14
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.cardRadius, padding: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, padding: padding, tint: tint))
    }
}

// MARK: - Section label

/// Small all-caps heading used above grouped content.
struct SectionLabel: View {
    let title: String
    var systemImage: String? = nil
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
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if paper.isActive {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon)
            }
            if !compact { Text(text) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(color.opacity(0.22)), in: Capsule())
        .help(text)
    }

    private var text: String {
        switch paper.statusKind {
        case .running: return paper.state == "queued" ? "Queued" : "Converting"
        case .done: return paper.read ? "Listened" : "Ready"
        case .error: return "Failed"
        case .unknown: return paper.state.isEmpty ? "Draft" : paper.state.capitalized
        }
    }

    private var icon: String {
        switch paper.statusKind {
        case .running: return "hourglass"
        case .done: return paper.read ? "checkmark.circle.fill" : "waveform"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "doc"
        }
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
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

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
