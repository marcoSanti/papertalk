#if os(Linux)
import Foundation
import SwiftCrossUI

/// The papers in the current scope, searchable, like the macOS library list.
struct LibraryPane: View {
    @State var bridge: StoreBridge

    var body: some View {
        let store = bridge.store
        let papers = store.filteredPapers()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LibraryPresentation.title(view: store.view, tag: store.activeTag, author: store.activeAuthor))
                    .font(.title2)
                Spacer()
                Button("Import PDF…") { store.beginImport() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            TextField("Search titles, authors, DOI (#tag for tags)", text: bridge.binding(\.search))
                .padding(.horizontal, 12)
            if papers.isEmpty {
                let text = LibraryPresentation.emptyStateText(
                    LibraryPresentation.emptyState(libraryIsEmpty: store.papers.isEmpty, search: store.search))
                VStack(spacing: 6) {
                    Text(text.title).font(.headline)
                    Text(text.message).foregroundColor(.gray)
                }
                .padding(40)
                Spacer()
            } else {
                List(papers, selection: bridge.binding(\.selectedId)) { paper in
                    PaperRow(bridge: bridge, paper: paper)
                }
                Spacer()
            }
            PaneWidth(400)
        }
    }
}

/// One paper: small cover, title, authors and status.
struct PaperRow: View {
    var bridge: StoreBridge
    var paper: Paper

    var body: some View {
        HStack(spacing: 10) {
            CoverView(bridge: bridge, paperId: paper.id, width: 40, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.displayTitle).lineLimit(2)
                Text(PaperPresentation.listSubtitle(paper)).font(.caption).foregroundColor(.gray).lineLimit(1)
                if PaperPresentation.showsStatusBadgeOnCover(paper) {
                    Text(PaperPresentation.statusText(paper)).font(.caption).foregroundColor(.orange)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// A paper's first page, or a plain placeholder until it's rendered.
struct CoverView: View {
    var bridge: StoreBridge
    var paperId: String
    var width: Double
    var height: Double

    var body: some View {
        if let image = bridge.cover(paperId) {
            Image(image).resizable().frame(width: width, height: height)
        } else {
            Color.gray.frame(width: width, height: height).cornerRadius(4)
        }
    }
}
#endif
