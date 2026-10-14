import SwiftUI

// MARK: - Flow tags (wrapping chip layout, removable)

struct FlowTags<Trailing: View>: View {
    let tags: [String]
    var onSelect: ((String) -> Void)? = nil
    var onRemove: (String) -> Void
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
    init(tags: [String], onRemove: @escaping (String) -> Void) {
        self.init(tags: tags, onSelect: nil, onRemove: onRemove, trailing: { EmptyView() })
    }
}

/// A single accent-tinted tag capsule; the remove button appears on hover.
struct TagChip: View {
    let tag: String
    var onSelect: (() -> Void)? = nil
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
            .help(onSelect == nil ? "" : "Show all papers tagged #\(tag)")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove tag")
            .accessibilityLabel("Remove tag \(tag)")
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
