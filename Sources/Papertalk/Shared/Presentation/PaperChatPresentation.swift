// The Ask window: its wording, the citations in an answer as links, and finding a cited quote.

import Foundation

/// What the Ask window shows.
extension PaperChat {
    /// The Ask window's first size: wide enough for the chat and the paper side by side.
    static let windowWidth: CGFloat = 1180

    /// `[[p. 3: "quote"]]`, with straight or curly quotes.
    private static let citationPattern = try! NSRegularExpression(
        pattern: #"\[\[\s*p(?:age|\.)?\s*(\d+)\s*:\s*["“]([^"”\]]+)["”]\s*\]\]"#, options: [.caseInsensitive])

    /// The link scheme of a citation in a rendered answer.
    static let citationScheme = "papertalk-source"

    /// `text` with each citation turned into a Markdown link labelled with its page, which
    /// `citation(from:)` reads back when it's clicked.
    static func linkingCitations(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in citationMatches(text) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let page = ns.substring(with: m.range(at: 1))
            let quote = ns.substring(with: m.range(at: 2))
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            out += "[\(L("p. {0}", page))](\(citationScheme):\(page)?\(quote))"
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// The citations in an answer, in order.
    static func citations(in text: String) -> [Citation] {
        let ns = text as NSString
        return citationMatches(text).compactMap { m in
            Int(ns.substring(with: m.range(at: 1))).map { Citation(page: $0, quote: ns.substring(with: m.range(at: 2))) }
        }
    }

    private static func citationMatches(_ text: String) -> [NSTextCheckingResult] {
        citationPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// The citation a clicked link points to; nil for any other link.
    static func citation(from url: URL) -> Citation? {
        guard url.scheme == citationScheme,
              let parts = url.absoluteString.dropFirst(citationScheme.count + 1).split(separator: "?", maxSplits: 1).first,
              let page = Int(parts), page > 0 else { return nil }
        let quote = url.absoluteString.split(separator: "?", maxSplits: 1).dropFirst().first
            .flatMap { String($0).removingPercentEncoding } ?? ""
        return Citation(page: page, quote: quote)
    }

    /// What to look for on the page, best first: the whole quote, then its opening words, since
    /// models misquote the ends and PDF text breaks lines and words.
    static func searchStrings(_ quote: String) -> [String] {
        let words = quote.split(whereSeparator: \.isWhitespace)
        var out: [String] = []
        for n in [words.count, 8, 5, 3] where n <= words.count && n > 0 {
            let s = words.prefix(n).joined(separator: " ")
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// Where `quote` is in a page's text, as a UTF-16 range of it. Case, accents, ligatures,
    /// punctuation, spacing, line breaks and words hyphenated across lines are ignored, since PDF
    /// text and a model's quote rarely agree on those.
    static func locate(_ quote: String, in pageText: String) -> NSRange? {
        let needle = String(normalized(quote).map(\.char)).trimmingCharacters(in: .whitespaces)
        let hay = normalized(pageText)
        guard !needle.isEmpty else { return nil }
        let chars = hay.map(\.char)
        let target = Array(needle)
        guard target.count <= chars.count else { return nil }
        for i in 0...(chars.count - target.count) where chars[i] == target[0] && Array(chars[i..<(i + target.count)]) == target {
            let start = hay[i].range.location, end = NSMaxRange(hay[i + target.count - 1].range)
            return NSRange(location: start, length: end - start)
        }
        return nil
    }

    /// `text` as lowercase letters and digits with single spaces between words, each character
    /// with the range of the original it came from.
    private static func normalized(_ text: String) -> [(char: Character, range: NSRange)] {
        var out: [(char: Character, range: NSRange)] = []
        var offset = 0
        var joining = false   // after a hyphen that ends a line: the word goes on
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            let range = NSRange(location: offset, length: String(c).utf16.count)
            offset += range.length
            if "-‐‑".contains(c), i + 1 < chars.count, chars[i + 1].isNewline { joining = true; continue }
            if c.isWhitespace && joining { continue }
            joining = false
            let folded = String(c).precomposedStringWithCompatibilityMapping
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            for f in folded {
                if f.isLetter || f.isNumber { out.append((f, range)) }
                else if out.last.map({ $0.char != " " }) ?? false { out.append((" ", range)) }
            }
        }
        return out
    }

    /// The source pane's title: the page shown, or "The paper" before any citation is opened.
    /// A deck's pages are its slides.
    static func sourceTitle(page: Int?, slides: Bool = false) -> String {
        if slides { return page.map { L("Slide {0}", $0) } ?? L("The deck") }
        return page.map { L("Page {0}", $0) } ?? L("The paper")
    }
    static var sourceLoading: String { L("Rendering pages…") }
    /// When the quote couldn't be found on its page: the page is still shown.
    static var sourceNotFound: String { L("The quoted words weren't found near this page.") }
    /// The note under the source pane's title: nil while searching or once the quote is highlighted.
    static func sourceNote(highlights: [CGRect]?) -> String? { highlights?.isEmpty == true ? sourceNotFound : nil }

    /// Send is enabled: there's a question and no answer is pending.
    static func canSend(_ draft: String, answering: Bool) -> Bool { !answering && question(draft) != nil }

    /// "Ask — Title", the window's title.
    static func windowTitle(_ p: Paper) -> String { L("Ask — {0}", p.displayTitle) }

    static func placeholder(slides: Bool = false) -> String { slides ? L("Ask about this deck…") : L("Ask about this paper…") }
    static func emptyTitle(slides: Bool = false) -> String { slides ? L("Ask about this deck") : L("Ask about this paper") }
    static func emptyHint(slides: Bool = false) -> String {
        slides ? L("Answers come from the slides and the deck's details. Try one of these, or type your own.")
            : L("Answers come from the paper's text and details. Try one of these, or type your own.")
    }
    static var sendHelp: String { L("Send (Return)") }
    static var clearTitle: String { L("New chat") }
    static func thinking(slides: Bool = false) -> String { slides ? L("Reading the slides…") : L("Reading the paper…") }

    /// Starter questions shown in an empty chat.
    static func suggestions(slides: Bool = false) -> [String] {
        [slides ? L("Summarize this deck in three sentences.") : L("Summarize this paper in three sentences."),
         L("What is the main contribution?"),
         L("How does the method work, step by step?"),
         L("What are the limitations?")]
    }

    #if os(macOS)
    /// An answer with its Markdown (bold, italics, code, links) rendered and its citations as page
    /// links; plain text if it doesn't parse. macOS only: Foundation on Linux has no Markdown parser.
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: linkingCitations(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
    #endif
}
