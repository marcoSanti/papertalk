// The Linux header above one author's papers, when the library is drilled in: back, avatar,
// name, counts and co-authors (each opening theirs).

#if os(Linux)
import Foundation
import SwiftCrossUI

/// Above the paper list when an author is selected: a back button to every author, the
/// author's avatar and name, a summary, and their co-authors as openings to those papers.
struct AuthorHeader: View {
    var bridge: StoreBridge
    let name: String

    var body: some View {
        let store = bridge.store
        let papers = store.papersByAuthor[name] ?? []
        let coauthors = AuthorsPresentation.coauthors(of: name, in: papers)
        VStack(alignment: .leading, spacing: 8) {
            Button(L("All authors")) { store.showAllAuthors() }
                .font(.caption)
            HStack(alignment: .top, spacing: 14) {
                AuthorAvatarView(name: name, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.title2).fontWeight(.semibold)
                    Text(AuthorsPresentation.summary(papers: papers.count, coauthors: coauthors.count))
                        .foregroundColor(.gray)
                    if !coauthors.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(coauthors.prefix(AuthorsPresentation.coauthorLimit), id: \.name) { co, shared in
                                Button {
                                    store.showAuthor(co)
                                } label: {
                                    HStack(spacing: 5) {
                                        AuthorAvatarView(name: co, size: 16)
                                        Text(co).font(.caption).lineLimit(1)
                                        if let sharedLabel = AuthorsPresentation.sharedLabel(shared) {
                                            Text(sharedLabel).font(.caption).foregroundColor(.gray)
                                        }
                                    }
                                    .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.blue.opacity(0.1)))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}
#endif