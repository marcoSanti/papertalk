// Suggested papers: what a source (Semantic Scholar, later Scholar alert emails) proposes, the
// record of what was shown and handled (`suggestions.json`), and the pure rules around them.

import Foundation

/// A paper a source proposes for the library, waiting in the Suggested Papers window.
struct Suggestion: Codable, Identifiable, Equatable {
    /// Where a suggestion came from.
    enum Source: String, Codable { case semanticScholar, scholarAlert }

    /// `Suggestions.key`: the DOI, else the normalised title; the same paper from two sources shares it.
    var id: String
    var title: String
    var authors: [String]
    var year: Int?
    var abstract: String?
    /// Bare DOI, when known.
    var doi: String?
    /// A page to open in the browser to get the PDF (the DOI's, else the source's).
    var pageURL: String?
    /// A free PDF that can be downloaded directly; nil when the browser is needed.
    var pdfURL: String?
    var source: Source
    /// The LLM's one line on why it fits the library; nil before ranking (or without an LLM).
    var reason: String?
}

/// `suggestions.json`: the suggestions still waiting, the keys never to show again (dismissed
/// or imported), and when the sources were last asked.
struct SuggestionLog: Codable, Equatable {
    var pending: [Suggestion] = []
    var handled: [String] = []
    /// ISO 8601; nil before the first check.
    var lastCheckIso: String?
    /// Alert emails already read (`ScholarAlerts.alertId`), so a check doesn't read them again.
    /// Optional, so logs written before alerts still decode.
    var readAlerts: [String]? = nil
}

/// The depth, length and language of the last import started from the import sheet, which
/// suggested papers are imported with.
struct ImportChoice: Codable, Equatable {
    var depth: String = Depth.inDepth.rawValue
    var depthNote = ""
    var targetMinutes: Int?
    var scriptLanguage: String?

    static let defaultsKey = "papertalk.lastImport"

    static func load(_ defaults: UserDefaults = .standard) -> ImportChoice {
        defaults.decoded(ImportChoice.self, forKey: defaultsKey) ?? ImportChoice()
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.setEncoded(self, forKey: Self.defaultsKey)
    }

    /// Unknown raw values (a depth or language removed later) fall back to the defaults.
    var resolvedDepth: Depth { Depth(rawValue: depth) ?? .inDepth }
    var resolvedLanguage: AppLanguage? { scriptLanguage.flatMap(AppLanguage.init(rawValue:)) }
}

/// The rules of suggested papers, as pure functions.
enum Suggestions {
    /// How many library papers are sent to Semantic Scholar as examples.
    static let maxSeeds = 100
    /// How many suggestions the LLM ranks at once (the newest pending ones beyond are left in order).
    static let maxRanked = 40

    /// Lowercased letters and digits, single spaces: "Attention Is All You Need!" → "attention is all you need".
    static func normalisedTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The identity of a paper across sources and the library: its DOI, else its title.
    static func key(title: String, doi: String?) -> String {
        let d = (doi ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return d.isEmpty ? "title:" + normalisedTitle(title) : "doi:" + d
    }

    /// Semantic Scholar ids for the library's papers with a DOI, newest imports first (decks left out).
    // shortcut: papers without a DOI aren't sent (a title lookup would cost one request each); add
    // `/graph/v1/paper/search/match` if libraries without DOIs get no suggestions.
    static func seeds(_ papers: [Paper]) -> [String] {
        papers.filter { !$0.isSlides && !$0.doi.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted(by: Paper.newestFirst)
            .prefix(maxSeeds)
            .map { "DOI:" + $0.doi.trimmingCharacters(in: .whitespaces) }
    }

    /// Add what a check `found` to the log, leaving out papers already pending, handled, in the
    /// library (by DOI or title) or repeated. Returns the new log and what was added.
    static func merge(_ found: [Suggestion], into log: SuggestionLog, library: [Paper]) -> (log: SuggestionLog, added: [Suggestion]) {
        var known = Set(log.handled).union(log.pending.map(\.id))
        for p in library {
            if !p.doi.isEmpty { known.insert(key(title: "", doi: p.doi)) }
            known.insert(key(title: p.displayTitle, doi: nil))
        }
        var out = log
        var added: [Suggestion] = []
        for s in found where !s.title.isEmpty {
            let titleKey = key(title: s.title, doi: nil)
            guard !known.contains(s.id), !known.contains(titleKey) else { continue }
            known.formUnion([s.id, titleKey])
            added.append(s)
        }
        out.pending += added
        return (out, added)
    }

    /// Checked at most once per calendar day.
    static func isDue(lastCheckIso: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let iso = lastCheckIso, let last = ISO8601DateFormatter().date(from: iso) else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// Move `ids` from pending to handled (dismissed or imported: never suggested again).
    static func handle(_ ids: Set<String>, in log: SuggestionLog) -> SuggestionLog {
        var out = log
        out.pending.removeAll { ids.contains($0.id) }
        out.handled += ids.filter { !log.handled.contains($0) }.sorted()
        return out
    }

    // MARK: Semantic Scholar

    /// The recommendations endpoint's reply, with only the fields asked for.
    private struct Recommendations: Decodable {
        struct Paper: Decodable {
            struct Author: Decodable { var name: String? }
            struct PDF: Decodable { var url: String? }
            var title: String?
            var authors: [Author]?
            var year: Int?
            var abstract: String?
            var externalIds: [String: StringOrInt]?
            var openAccessPdf: PDF?
            var url: String?
        }
        var recommendedPapers: [Paper]
    }

    /// `externalIds` mixes strings (DOI) and numbers (CorpusId).
    private enum StringOrInt: Decodable {
        case string(String), other
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            self = (try? c.decode(String.self)).map(Self.string) ?? .other
        }
        var string: String? { if case .string(let s) = self { return s } else { return nil } }
    }

    /// The `fields` asked of Semantic Scholar, matching `Recommendations.Paper`.
    static let semanticScholarFields = "title,authors,year,abstract,externalIds,openAccessPdf,url"

    /// Suggestions from a Semantic Scholar recommendations reply; nil when it isn't one. An empty
    /// `openAccessPdf.url` means no free PDF; an arXiv paper always has one.
    static func parseSemanticScholar(_ data: Data) -> [Suggestion]? {
        guard let reply = try? JSONDecoder().decode(Recommendations.self, from: data) else { return nil }
        return reply.recommendedPapers.compactMap { p in
            guard let title = p.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let doi = p.externalIds?["DOI"]?.string
            let arxiv = p.externalIds?["ArXiv"]?.string
            let openPdf = p.openAccessPdf?.url.flatMap { $0.isEmpty ? nil : $0 }
            return Suggestion(id: key(title: title, doi: doi), title: title,
                              authors: (p.authors ?? []).compactMap(\.name), year: p.year,
                              abstract: p.abstract, doi: doi,
                              pageURL: doi.map { CitedPaper.resolver + $0 } ?? p.url,
                              pdfURL: openPdf ?? arxiv.map { "https://arxiv.org/pdf/" + $0 },
                              source: .semanticScholar, reason: nil)
        }
    }

    // MARK: Ranking by the LLM

    /// The ranking request: the library's titles, then the numbered candidates.
    static func rankingInput(library: [String], candidates: [Suggestion]) -> String {
        let lib = library.prefix(maxSeeds).map { "- " + $0 }.joined(separator: "\n")
        let cands = candidates.enumerated().map { i, s in
            let year = s.year.map { " (\($0))" } ?? ""
            let abstract = (s.abstract ?? "").prefix(300)
            return "\(i + 1). \(s.title)\(year)" + (abstract.isEmpty ? "" : "\n   " + abstract)
        }.joined(separator: "\n")
        return "LIBRARY:\n\(lib)\n\nCANDIDATES:\n\(cands)"
    }

    /// The LLM's ranking applied to `candidates`: the listed ones first, in its order and with its
    /// reason, then the rest as they were. Nil when the reply can't be read.
    static func applyRanking(_ raw: String, to candidates: [Suggestion]) -> [Suggestion]? {
        struct Reply: Decodable {
            struct Entry: Decodable { var n: Int; var why: String? }
            var ranked: [Entry]
        }
        guard let json = LLMReply.json(raw), let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        var used = Set<Int>()
        var out: [Suggestion] = []
        for e in reply.ranked where candidates.indices.contains(e.n - 1) && !used.contains(e.n - 1) {
            used.insert(e.n - 1)
            var s = candidates[e.n - 1]
            let why = e.why?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            s.reason = why.isEmpty ? nil : why
            out.append(s)
        }
        return out + candidates.indices.filter { !used.contains($0) }.map { candidates[$0] }
    }

    // MARK: Getting the PDF

    /// Whether a PDF's opening text looks like the paper titled `title`: most of the title's longer
    /// words appear in it. True when the title has no such words (nothing to compare).
    static func titleMatches(_ title: String, text: String) -> Bool {
        let words: Set<String> = Set(normalisedTitle(title).split(separator: " ").map(String.init).filter { $0.count > 3 })
        guard !words.isEmpty else { return true }
        let found: Set<String> = Set(normalisedTitle(text).split(separator: " ").map(String.init))
        return Double(words.intersection(found).count) / Double(words.count) >= 0.6
    }

    /// Suffixes browsers give a download in progress (Chrome, Safari, Firefox).
    private static let partialSuffixes = [".crdownload", ".download", ".part"]

    /// The PDF that finished downloading into the folder since `before` was listed, given the
    /// folder's files and sizes now and at the previous poll. A file counts once it isn't empty,
    /// its size held still between two polls and no partial copy sits beside it (Firefox makes an
    /// empty placeholder first).
    static func finishedPDF(now: [String: Int64], previous: [String: Int64], before: Set<String>) -> String? {
        now.keys.filter { name in
            guard name.lowercased().hasSuffix(".pdf"), !before.contains(name),
                  let size = now[name], size > 0, previous[name] == size else { return false }
            return !partialSuffixes.contains { now[name + $0] != nil }
        }.sorted().first
    }

    /// A file name for a downloaded PDF: the title without characters file systems refuse.
    static func fileName(for s: Suggestion) -> String {
        let cleaned = s.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: " ")
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) + ".pdf"
    }
}
