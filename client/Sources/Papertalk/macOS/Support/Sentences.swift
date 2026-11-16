// Sentence enumeration on macOS: Foundation's own sentence boundaries (Linux has a
// stand-in in `Linux/SentencesCompat.swift`, since swift-corelibs-foundation lacks them).

#if os(macOS)
import Foundation

/// Walks the sentences of a text, as `enumerateSubstrings(options: .bySentences)` does.
enum Sentences {
    /// Calls `body` with each sentence (trailing whitespace included) until it sets `stop`.
    static func forEach(in text: String, _ body: (String, inout Bool) -> Void) {
        // Darwin's enumerateSubstrings takes an escaping closure, but calls it only before it
        // returns, so `body` doesn't really escape.
        withoutActuallyEscaping(body) { body in
            text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, stop in
                guard let s else { return }
                var halt = false
                body(s, &halt)
                if halt { stop = true }
            }
        }
    }
}
#endif
