// Small text and collection helpers used in every layer.

import Foundation

extension StringProtocol {
    /// Spoken words: runs of anything but whitespace.
    var wordCount: Int { split(whereSeparator: \.isWhitespace).count }
    /// The words with single spaces between them.
    var singleSpaced: String { split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

extension String {
    /// Each run of whitespace as one space (the ends aren't trimmed).
    var collapsingWhitespace: String { replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
    /// A typed one-line value, tidied: whitespace collapsed, ends trimmed.
    var tidiedLine: String { collapsingWhitespace.trimmingCharacters(in: .whitespaces) }
    /// A base URL as paths are appended to it.
    var withoutTrailingSlashes: String { replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
    /// nil for an empty string, for `??` chains.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Sequence where Element: Hashable {
    /// How many times each element occurs.
    func occurrences() -> [Element: Int] { reduce(into: [:]) { $0[$1, default: 0] += 1 } }

    /// Each element once, in the order first seen.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
