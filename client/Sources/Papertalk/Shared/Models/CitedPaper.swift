// One entry of a paper's reference list, and the parsers that read it from a Crossref record
// or from the LLM's reply.

import Foundation

/// A paper cited by a library paper. Only `title` is always there.
struct CitedPaper: Codable, Equatable, Hashable {
    /// The cited work's title, or the whole reference text when the source gave nothing finer.
    var title: String
    /// Authors as one line (Crossref often gives only the first author's surname).
    var authors: String? = nil
    var year: String? = nil
    /// Bare DOI.
    var doi: String? = nil

    /// The `reference` list of a Crossref `/works/<doi>` message; empty when it has none.
    static func fromCrossref(_ message: [String: Any]) -> [CitedPaper] {
        let list = message["reference"] as? [[String: Any]] ?? []
        return list.compactMap { r in
            func str(_ k: String) -> String? { clean(r[k] as? String) }
            guard let title = str("article-title") ?? str("volume-title") ?? str("unstructured")
                ?? str("journal-title") else { return nil }
            return CitedPaper(title: title, authors: str("author"), year: str("year"), doi: bareDOI(str("DOI")))
        }
    }

    /// The `references` array of the LLM's JSON object; empty when it's missing or unreadable.
    static func fromLLM(_ obj: [String: Any]) -> [CitedPaper] {
        let list = obj["references"] as? [[String: Any]] ?? []
        return list.compactMap { r in
            func str(_ k: String) -> String? {
                if let n = r[k] as? Int { return String(n) }
                return clean(r[k] as? String)
            }
            guard let title = str("title") else { return nil }
            return CitedPaper(title: title, authors: str("authors"), year: str("year"), doi: bareDOI(str("doi")))
        }
    }

    /// The text from the last References / Bibliography heading to the end, nil when there is none.
    static func referencesSection(of text: String) -> String? {
        let headings: Set<String> = ["references", "bibliography", "works cited", "literature cited", "reference"]
        let lines = text.components(separatedBy: .newlines)
        // A heading may be numbered ("7 References", "VII. REFERENCES").
        guard let start = lines.lastIndex(where: { line in
            let words = line.lowercased().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^[0-9ivxlc]+\.?\s+"#, with: "", options: .regularExpression)
            return headings.contains(words)
        }) else { return nil }
        let body = lines[(start + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// A DOI without its `doi:` or `https://doi.org/` prefix.
    static func bareDOI(_ s: String?) -> String? {
        guard var d = clean(s) else { return nil }
        if d.lowercased().hasPrefix("doi:") { d = String(d.dropFirst(4)) }
        if let r = d.range(of: "doi.org/") { d = String(d[r.upperBound...]) }
        return clean(d)
    }

    private static func clean(_ s: String?) -> String? {
        let t = (s ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
