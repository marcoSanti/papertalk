// The Linux Authors screen: everyone in the library like a contact book, tapped to open
// their papers. Shown in place of the paper list while browsing the author index.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// Contact-book style browsing of the library by author: an A–Z index keyed on surname, one
/// card per author with their avatar and paper count. Tapping a card opens that author's
/// papers; the store's `showsAuthorIndex` decides when this replaces the paper list.
struct AuthorsPane: View {
    var bridge: StoreBridge

    var body: some View {
        let store = bridge.store
        let sections = AuthorsPresentation.sections(store.papersByAuthor, search: store.search)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Authors")).font(.title2)
                Spacer()
                if store.authorCounts.count > 0 {
                    Text(LibraryPresentation.authorsSubtitle(store.authorCounts.count))
                        .font(.caption).foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            TextField(L("Search titles, authors, DOI (#tag for tags)"), text: bridge.binding(\.search))
                .padding(.horizontal, 12)
            if store.authorCounts.isEmpty {
                VStack(spacing: 6) {
                    Text(L("No authors yet")).font(.headline)
                    Text(L("Authors appear once a paper's metadata has been extracted."))
                        .foregroundColor(.gray)
                }
                .padding(40)
                Spacer()
            } else if sections.isEmpty {
                VStack(spacing: 6) {
                    let text = LibraryPresentation.emptyStateText(
                        LibraryPresentation.emptyState(libraryIsEmpty: false, search: store.search))
                    Text(text.title).font(.headline)
                    Text(text.message).font(.caption).foregroundColor(.gray)
                }
                .padding(40)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    ForEach(sections, id: \.letter) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.letter)
                                .font(.headline).fontWeight(.bold)
                                .foregroundColor(.blue)
                                .padding(.top, 12)
                            ForEach(section.entries) { entry in
                                AuthorCardView(bridge: bridge, name: entry.name, papers: entry.papers)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                Spacer()
            }
            PaneWidth(400)
        }
    }
}

/// One author: avatar, name and paper count; opens their papers.
struct AuthorCardView: View {
    var bridge: StoreBridge
    let name: String
    let papers: [Paper]

    var body: some View {
        Button {
            bridge.store.showAuthor(name)
        } label: {
            HStack(spacing: 12) {
                AuthorAvatarView(name: name, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout).fontWeight(.semibold).lineLimit(2)
                    Text(LibraryPresentation.paperCount(papers.count))
                        .font(.caption).foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(12)
            .background(Capsule().fill(Color.blue.opacity(0.07)))
        }
    }
}

/// Round initials avatar in a colour stable per person, like the macOS AuthorAvatar.
struct AuthorAvatarView: View {
    let name: String
    var size: Double = 24

    var body: some View {
        ZStack(alignment: .center) {
            Circle().fill(SpeakerPalette.color(for: name))
                .frame(width: size, height: size)
            Text(AuthorName.initials(name))
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
        }
    }
}
#endif