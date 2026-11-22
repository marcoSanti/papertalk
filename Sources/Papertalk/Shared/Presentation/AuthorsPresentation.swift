// The Authors screen: author names normalised and sorted like a contact book, grouped A–Z,
// with co-authors and cover stacks for each.

import Foundation

/// The Authors screen and the single-author header.
enum AuthorsPresentation {
    /// One author with their papers, newest first.
    struct Entry: Identifiable, Equatable {
        let name: String
        let papers: [Paper]
        var id: String { name }
    }

    /// The authors under one index letter.
    struct Section: Equatable {
        let letter: String
        var entries: [Entry]
    }

    /// Authors matching the search, grouped A–Z by surname. A `#tag` search
    /// is about tags, so it doesn't filter authors.
    static func sections(_ byAuthor: [String: [Paper]], search: String) -> [Section] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = byAuthor.keys
            .filter { q.isEmpty || q.hasPrefix("#") || $0.lowercased().contains(q) }
            .sorted { AuthorName.sortKey($0).localizedCompare(AuthorName.sortKey($1)) == .orderedAscending }
            .map { Entry(name: $0, papers: byAuthor[$0] ?? []) }
        var out: [Section] = []
        for e in entries {
            let letter = AuthorName.indexLetter(e.name)
            if out.last?.letter == letter { out[out.count - 1].entries.append(e) }
            else { out.append(Section(letter: letter, entries: [e])) }
        }
        return out
    }

    /// The A–Z jump strip only earns its space once there are a few letters.
    static func showsLetterIndex(sectionCount: Int) -> Bool { sectionCount > 4 }

    /// Co-authors of `author` ranked by papers shared, then by name.
    static func coauthors(of author: String, in papers: [Paper]) -> [(name: String, shared: Int)] {
        let counts = papers.flatMap { Set($0.authors.map(AuthorName.clean)) }
            .filter { !$0.isEmpty && $0 != author }.occurrences()
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, shared: $0.value) }
    }

    /// The newest few covers shown on an author's card, and how many more there are.
    static func coverStack(_ papers: [Paper], limit: Int = 3) -> (shown: [Paper], more: Int) {
        let shown = Array(papers.prefix(limit))
        return (shown, papers.count - shown.count)
    }

    /// "+4" after the fanned covers, nil when every cover is shown.
    static func moreLabel(_ more: Int) -> String? { more > 0 ? "+\(more)" : nil }
    /// The co-authors listed in an author's header, most shared papers first.
    static let coauthorLimit = 10
    /// The co-authors the header lists.
    static func shownCoauthors(_ all: [(name: String, shared: Int)]) -> [(name: String, shared: Int)] {
        Array(all.prefix(coauthorLimit))
    }
    /// How many papers a co-author shares, shown only when more than one.
    static func sharedLabel(_ shared: Int) -> String? { shared > 1 ? "\(shared)" : nil }

    /// "3 papers · 5 co-authors" under an author's name.
    static func summary(papers: Int, coauthors: Int) -> String {
        let p = LibraryPresentation.paperCount(papers)
        guard coauthors > 0 else { return p }
        return p + " · " + LibraryPresentation.count(coauthors, L("1 co-author"), L("{0} co-authors"))
    }
}
