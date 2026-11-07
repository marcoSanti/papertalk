// What the Cited papers row and sheet show: the row's wording, each reference's line, link and
// copy text, and which references are already in the library.

import Foundation

enum CitedPapersPresentation {
    /// The Details row's button ("Show 12 cited papers"); nil when the paper lists none.
    static func showLabel(_ p: Paper) -> String? {
        let n = p.references?.count ?? 0
        return n == 0 ? nil : LibraryPresentation.count(n, L("Show 1 cited paper"), L("Show {0} cited papers"))
    }

    /// The sheet's title line under its heading.
    static func subtitle(_ p: Paper) -> String { p.displayTitle }

    /// Authors and year under a reference's title; nil when neither is known.
    static func byline(_ r: CitedPaper) -> String? {
        let s = [r.authors, r.year].compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }

    /// Its DOI page, else a Google Scholar search for the title.
    static func link(_ r: CitedPaper) -> URL? {
        if let doi = r.doi, let url = PaperPresentation.doiURL(doi) { return url }
        var c = URLComponents(string: "https://scholar.google.com/scholar")
        c?.queryItems = [URLQueryItem(name: "q", value: r.title)]
        return c?.url
    }

    /// The tooltip of the link button.
    static func linkHelp(_ r: CitedPaper) -> String { r.doi == nil ? L("Search Google Scholar") : L("Open DOI") }

    /// One plain-text line: "Authors (Year). Title. doi:…".
    static func copyText(_ r: CitedPaper) -> String {
        var s = r.authors.map { $0 + " " } ?? ""
        if let y = r.year { s += "(\(y)). " } else if !s.isEmpty { s = s.trimmingCharacters(in: .whitespaces) + ". " }
        s += r.title.hasSuffix(".") ? r.title : r.title + "."
        if let d = r.doi { s += " doi:" + d }
        return s
    }

    /// The library paper this reference is (same DOI, else the same title), other than `citing` itself.
    static func match(_ r: CitedPaper, in papers: [Paper], citing: String) -> Paper? {
        let doi = r.doi?.lowercased(), title = normalized(r.title)
        return papers.first { $0.id != citing && !$0.doi.isEmpty && $0.doi.lowercased() == doi }
            ?? papers.first { $0.id != citing && !title.isEmpty && normalized($0.title ?? "") == title }
    }

    /// Letters and digits only, lowercased, so punctuation and spacing don't stop a title match.
    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
