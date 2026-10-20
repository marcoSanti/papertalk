import Foundation

/// Author names as the library treats them: tidied, sorted by surname.
enum AuthorName {
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Ada Lovelace" sorts as "Lovelace Ada", like a contact book.
    static func sortKey(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last else { return name }
        return last + " " + parts.dropLast().joined(separator: " ")
    }

    static func indexLetter(_ name: String) -> String {
        let c = sortKey(name).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first
        guard let c, c.isLetter else { return "#" }
        return String(c).uppercased()
    }

    /// Avatar initials: first and last name ("Ada Lovelace" → "AL", "Plato" → "P").
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }
}

/// The Authors screen and the single-author header.
enum AuthorsPresentation {
    struct Entry: Identifiable, Equatable {
        let name: String
        let papers: [Paper]
        var id: String { name }
    }

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
        var counts: [String: Int] = [:]
        for p in papers {
            for a in Set(p.authors.map(AuthorName.clean)) where !a.isEmpty && a != author {
                counts[a, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, shared: $0.value) }
    }

    /// The newest few covers shown on an author's card, and how many more there are.
    static func coverStack(_ papers: [Paper], limit: Int = 3) -> (shown: [Paper], more: Int) {
        let shown = Array(papers.prefix(limit))
        return (shown, papers.count - shown.count)
    }

    /// "3 papers · 5 co-authors" under an author's name.
    static func summary(papers: Int, coauthors: Int) -> String {
        let p = LibraryPresentation.paperCount(papers)
        guard coauthors > 0 else { return p }
        return p + " · " + LibraryPresentation.count(coauthors, L("1 co-author"), L("{0} co-authors"))
    }
}
