// Author names as the library matches and sorts them.

import Foundation

/// Author names as the library treats them: tidied, sorted by surname.
enum AuthorName {
    /// The name with runs of whitespace collapsed, so "Ada  Lovelace" is one author.
    static func clean(_ s: String) -> String {
        s.singleSpaced
    }

    /// "Ada Lovelace" sorts as "Lovelace Ada", like a contact book.
    static func sortKey(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last else { return name }
        return last + " " + parts.dropLast().joined(separator: " ")
    }

    /// The A–Z section a name falls in (by surname, accents ignored); "#" for the rest.
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
