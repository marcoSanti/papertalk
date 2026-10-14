import SwiftUI

// MARK: - Flow tags (chip layout, removable)
struct FlowTags: View {
    let tags: [String]
    var onRemove: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunks, id: \.self) { row in
                HStack(spacing: 6) { ForEach(row, id: \.self) { chip($0) } }
            }
        }
    }
    private var chunks: [[String]] { stride(from: 0, to: tags.count, by: 3).map { Array(tags[$0..<min($0+3, tags.count)]) } }
    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)").font(.caption)
            Button { onRemove(tag) } label: { Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.appAccent.opacity(0.12), in: Capsule())
    }
}