// Tag chips: a single removable chip and a wrapping row of them.

#if os(macOS)
import SwiftUI

// MARK: - Flow tags (wrapping chip layout, removable)

/// Tags as chips that wrap onto new lines, with optional trailing content (the add field).
struct FlowTags<Trailing: View>: View {
    let tags: [String]
    /// Clicking a chip (shows that tag's papers); nil makes chips inert.
    var onSelect: ((String) -> Void)? = nil
    /// The chip's remove button.
    var onRemove: (String) -> Void
    /// Shown after the last chip, on the same flow.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag,
                        onSelect: onSelect == nil ? nil : { onSelect?(tag) },
                        onRemove: { onRemove(tag) })
            }
            trailing()
        }
        .animation(.snappy, value: tags)
    }
}

extension FlowTags where Trailing == EmptyView {
    /// Chips with nothing after them, not clickable.
    init(tags: [String], onRemove: @escaping (String) -> Void) {
        self.init(tags: tags, onSelect: nil, onRemove: onRemove, trailing: { EmptyView() })
    }
}

/// A single accent-tinted tag capsule; the remove button appears on hover.
/// One "#tag" capsule; the remove button appears on hover.
struct TagChip: View {
    let tag: String
    /// Clicking the chip; nil makes it inert.
    var onSelect: (() -> Void)? = nil
    /// The remove button.
    var onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button { onSelect?() } label: {
                Text("#\(tag)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(onSelect == nil ? "" : L("Show all papers tagged #{0}", tag))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
            .help(L("Remove tag"))
            .accessibilityLabel(L("Remove tag {0}", tag))
        }
        .foregroundStyle(Color.appAccent)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .background(Color.appAccent.opacity(hovering ? 0.22 : 0.14), in: Capsule())
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
        .transition(.scale.combined(with: .opacity))
    }
}

#endif
