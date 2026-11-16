// The Linux tag editor: the paper's tags as removable chips, an add field, and the library's
// most-used tags suggested as one-click adds.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// The tags card under the details pane's actions: removable chips that show a tag's papers,
/// an add field, and suggested tags pulled from the library's common ones (macOS DetailView).
struct TagEditor: View {
    var bridge: StoreBridge
    let paper: Paper
    /// The tag being typed in the add field.
    @State var newTag = ""

    var body: some View {
        let store = bridge.store
        let suggested = PaperPresentation.suggestedTags(for: paper, tagCounts: store.tagCounts)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Tags")).font(.headline)
                if let count = LibraryPresentation.badge(paper.tags.count) {
                    Text(count).font(.caption).foregroundColor(.gray)
                }
            }
            if !paper.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(paper.tags, id: \.self) { tag in
                        TagChipView(bridge: bridge, paperId: paper.id, tag: tag)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(L("Add tag"), text: $newTag)
                    .frame(width: 150)
                Button(L("Add tag")) { add() }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !suggested.isEmpty {
                HStack(spacing: 6) {
                    Text(L("Suggested")).font(.caption).foregroundColor(.gray)
                    ForEach(suggested, id: \.self) { tag in
                        Button(PaperPresentation.suggestionLabel(tag)) { store.addTag(paper.id, tag) }
                            .font(.caption)
                    }
                }
            }
        }
    }

    /// Add the typed tag and clear the field.
    private func add() {
        let store = bridge.store
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        store.addTag(paper.id, tag)
        newTag = ""
    }
}

/// One removable "#tag" chip: click to see that tag's papers, an × to drop it.
struct TagChipView: View {
    var bridge: StoreBridge
    let paperId: String
    let tag: String

    var body: some View {
        HStack(spacing: 6) {
            Button(PaperPresentation.tagLabel(tag)) {
                bridge.store.showTag(tag)
            }
            .font(.caption)
            Button("×") { bridge.store.removeTag(paperId, tag) }
                .font(.caption)
                .help(L("Remove tag"))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.blue.opacity(0.14)))
        .foregroundColor(.blue)
    }
}
#endif