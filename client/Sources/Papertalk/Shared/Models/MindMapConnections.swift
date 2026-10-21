// Connections between papers' mind maps: a local shortlist of concepts that look related, the
// LLM's verdict on that shortlist, and copying the result onto the other papers' maps.

import Foundation

/// Finds which concepts of a newly drawn mind map relate to concepts in the library's other maps.
///
/// Sending every other map to the LLM grows with the library (20–30 concepts with sentences each,
/// per paper) and soon overflows a model's context. So a cheap local pass shortlists pairs that
/// share rare words (TF-IDF weighted), bounded by `maxPairs` and `maxPapers`, and the LLM only
/// judges and names that shortlist: its prompt stays the same size however big the library gets,
/// and with no likely pairs it isn't called at all.
enum MindMapConnections {
    /// A pair worth showing the LLM: a concept here and one in another paper's map.
    struct Candidate: Equatable {
        let from: String
        let paperId: String
        let nodeId: String
        let score: Double
    }

    /// Bounds on the shortlist, so the prompt stays small.
    static let maxPairs = 40, maxPapers = 8, perConcept = 3
    /// The weakest similarity still worth asking about (cosine, 0–1).
    static let minScore = 0.12
    /// At most this many connections are kept from one reply.
    static let maxLinks = 12

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "its", "into", "than",
        "which", "their", "they", "them", "these", "those", "such", "can", "has", "have", "not", "but",
        "how", "what", "when", "where", "why", "who", "each", "both", "more", "most", "other", "over",
        "under", "between", "about", "also", "only", "using", "used", "use", "based", "paper", "approach",
        "method", "methods", "problem", "result", "results", "show", "shows", "work", "new", "our", "it's",
        "evidence", "experiment", "experiments", "evaluation", "demonstration", "study", "analysis", "proposed",
        "performance", "task", "tasks", "key", "main", "general",
    ]

    /// A concept's words: lowercased, without stopwords and short words, plural "s" dropped.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap { w -> String? in
            guard w.count >= 3, !stopwords.contains(String(w)) else { return nil }
            return w.count > 4 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : String(w)
        })
    }

    private static func text(_ n: MindMap.Node) -> String { "\(n.label) \(n.core) \(n.description)" }

    /// The likeliest related pairs between `map` and the `others` (paper id → map), best first.
    static func candidates(for map: MindMap, among others: [String: MindMap]) -> [Candidate] {
        let mine = map.nodes.map { ($0.id, words(text($0))) }
        let theirs = others.sorted { $0.key < $1.key }.flatMap { pid, m in m.nodes.map { (pid, $0.id, words(text($0))) } }
        guard !mine.isEmpty, !theirs.isEmpty else { return [] }

        // Rare words count most: inverse document frequency over every concept.
        var df: [String: Double] = [:]
        for set in mine.map(\.1) + theirs.map(\.2) { for w in set { df[w, default: 0] += 1 } }
        let total = Double(mine.count + theirs.count)
        let idf = df.mapValues { log(1 + total / $0) }
        // One shared word is only a hint when it's rare: in at most two concepts in all.
        let rare = Set(df.filter { $0.value <= 2 }.keys)
        func norm(_ s: Set<String>) -> Double { sqrt(s.reduce(0) { $0 + pow(idf[$1] ?? 0, 2) }) }
        let theirNorms = theirs.map { norm($0.2) }

        var best: [Candidate] = []
        for (from, set) in mine {
            let n = norm(set)
            guard n > 0 else { continue }
            var scored: [Candidate] = []
            for (i, t) in theirs.enumerated() where theirNorms[i] > 0 {
                let shared = set.intersection(t.2)
                guard shared.count >= 2 || shared.contains(where: rare.contains) else { continue }
                let score = shared.reduce(0) { $0 + pow(idf[$1] ?? 0, 2) } / (n * theirNorms[i])
                if score >= minScore { scored.append(Candidate(from: from, paperId: t.0, nodeId: t.1, score: score)) }
            }
            best += scored.sorted { $0.score > $1.score }.prefix(perConcept)
        }
        best.sort { $0.score != $1.score ? $0.score > $1.score : ($0.from, $0.nodeId) < ($1.from, $1.nodeId) }
        // Keep the papers with the strongest matches.
        var papers: [String] = []
        for c in best where !papers.contains(c.paperId) && papers.count < maxPapers { papers.append(c.paperId) }
        return Array(best.filter { papers.contains($0.paperId) }.prefix(maxPairs))
    }

    /// The pairs as numbered lines for the LLM.
    static func pairList(_ candidates: [Candidate], map: MindMap, others: [String: MindMap],
                         titles: [String: String]) -> String {
        candidates.enumerated().compactMap { i, c -> String? in
            guard let a = map.node(c.from), let b = others[c.paperId]?.node(c.nodeId) else { return nil }
            return "\(i + 1). THIS PAPER: \(a.label) (\(a.core)) <-> \"\(titles[c.paperId] ?? "")\": \(b.label) (\(b.core))"
        }.joined(separator: "\n")
    }

    /// Read the LLM's verdict (`{"links": [{"pair": n, "label": "…"}]}`) into connections; pairs
    /// it didn't confirm, unknown numbers and repeats are dropped.
    static func parse(_ raw: String, candidates: [Candidate], others: [String: MindMap],
                      titles: [String: String]) -> [MindMap.ExternalLink] {
        guard let json = LocalPipeline.extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let items = obj["links"] as? [[String: Any]] else { return [] }
        var out: [MindMap.ExternalLink] = []
        for item in items {
            let n = (item["pair"] as? NSNumber)?.intValue ?? Int((item["pair"] as? String) ?? "") ?? 0
            let label = MindMap.shortLabel((item["label"] as? String) ?? "")
            guard n >= 1, n <= candidates.count, !label.isEmpty else { continue }
            let c = candidates[n - 1]
            guard let node = others[c.paperId]?.node(c.nodeId),
                  !out.contains(where: { $0.from == c.from && $0.paperId == c.paperId && $0.nodeId == c.nodeId }) else { continue }
            out.append(MindMap.ExternalLink(from: c.from, paperId: c.paperId, paperTitle: titles[c.paperId] ?? "",
                                            nodeId: c.nodeId, nodeLabel: node.label, label: label))
        }
        return Array(out.prefix(maxLinks))
    }

    /// The other papers' maps with their side of `links` (of paper `id`, titled `title`, map `map`):
    /// old connections to `id` are replaced. Only maps that changed are returned.
    static func mirrored(_ links: [MindMap.ExternalLink], of id: String, title: String, map: MindMap,
                         into others: [String: MindMap]) -> [String: MindMap] {
        var changed: [String: MindMap] = [:]
        for (pid, var other) in others {
            let before = other.externalLinks
            // shortcut: the label is kept as the LLM wrote it from this paper's side, so a directed
            // relation ("builds on") reads backwards there; store a direction if that confuses people.
            let back = links.filter { $0.paperId == pid }.compactMap { l -> MindMap.ExternalLink? in
                guard let node = map.node(l.from) else { return nil }
                return MindMap.ExternalLink(from: l.nodeId, paperId: id, paperTitle: title,
                                            nodeId: l.from, nodeLabel: node.label, label: l.label)
            }
            let after = before.filter { $0.paperId != id } + back
            guard after != before else { continue }
            other.external = after.isEmpty ? nil : after
            changed[pid] = other
        }
        return changed
    }
}
