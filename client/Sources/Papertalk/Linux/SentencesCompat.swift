// Linux stand-in for Foundation's sentence enumeration (`.bySentences` is unavailable in
// swift-corelibs-foundation): a plain punctuation-based splitter.

#if os(Linux)
import Foundation

/// Walks the sentences of a text, like `enumerateSubstrings(options: .bySentences)` on macOS.
enum Sentences {
    /// Marks that can end a sentence.
    private static let enders: Set<Character> = [".", "!", "?", "…"]
    /// Closing quotes and brackets that stay with the sentence they close.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    /// Calls `body` with each sentence (trailing whitespace included, as on macOS) until it
    /// sets `stop`. A sentence ends at `.`, `!`, `?` or `…` (with any closing quotes) followed
    /// by whitespace and a word that doesn't start in lower case ("e.g. this" stays one), or
    /// at a line break.
    static func forEach(in text: String, _ body: (String, inout Bool) -> Void) {
        let chars = Array(text)
        var start = 0, i = 0
        var stop = false
        func emit(upTo end: Int) {
            guard end > start, !stop else { return }
            body(String(chars[start..<end]), &stop)
            start = end
        }
        while i < chars.count, !stop {
            let c = chars[i]
            if c.isNewline {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                emit(upTo: j)
                i = j
                continue
            }
            if enders.contains(c) {
                var j = i + 1
                while j < chars.count, enders.contains(chars[j]) || closers.contains(chars[j]) { j += 1 }
                var k = j
                while k < chars.count, chars[k].isWhitespace, !chars[k].isNewline { k += 1 }
                let atEnd = k == chars.count
                let breaks = atEnd || (k > j && !(chars[k].isLowercase || chars[k].isNumber)) || chars[k].isNewline
                if breaks {
                    while k < chars.count, chars[k].isWhitespace { k += 1 }
                    emit(upTo: k)
                    i = k
                    continue
                }
                i = j
                continue
            }
            i += 1
        }
        emit(upTo: chars.count)
    }
}
#endif
