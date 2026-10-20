import Foundation

/// A paper's mind map ("mappa mentale"): its key concepts as a tree under
/// three pillars (the problem, the method, the demonstration), plus a few
/// links across branches. Saved as `mindmap.json` beside the paper.
struct MindMap: Codable, Equatable {
    enum Branch: String, Codable, CaseIterable {
        case problem, method, evidence
    }

    struct Node: Codable, Equatable, Identifiable {
        var id: String
        /// The concept's name, short enough to label a node.
        var label: String
        var branch: Branch
        /// nil for the branch's main concept.
        var parent: String?
        var description: String
        /// Its key feature, finding or number, in one sentence.
        var core: String
    }

    struct Link: Codable, Equatable {
        var from: String
        var to: String
        var label: String
    }

    var nodes: [Node]
    var links: [Link]

    /// The branch's main concept.
    func root(_ branch: Branch) -> Node? { nodes.first { $0.branch == branch && $0.parent == nil } }
    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    func children(of id: String) -> [Node] { nodes.filter { $0.parent == id } }

    /// Whether every pillar is broken down into at least two parts.
    var isExpanded: Bool {
        Branch.allCases.allSatisfy { b in root(b).map { children(of: $0.id).count >= 2 } ?? false }
    }

    static let maxLabelLength = 32

    /// A label that fits a node: at most `maxLabelLength` characters, cut at a word.
    static func shortLabel(_ text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
        guard clean.count > maxLabelLength else { return clean }
        var out = ""
        for word in clean.split(separator: " ") {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.count > maxLabelLength - 1 { break }
            out = next
        }
        return (out.isEmpty ? String(clean.prefix(maxLabelLength - 1)) : out) + "…"
    }

    /// Read the LLM's reply leniently: keep every usable concept, attach
    /// orphans to their branch's main concept, break parent cycles, and drop
    /// links to concepts that don't exist. nil unless all three pillars are there.
    static func parse(_ raw: String) -> MindMap? {
        guard let json = LocalPipeline.extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let rawNodes = obj["nodes"] as? [[String: Any]] else { return nil }
        func str(_ v: Any?) -> String { ((v as? String) ?? (v as? NSNumber)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        // First pass: concepts with an id and a label, ids unique.
        var nodes: [Node] = []
        var declaredBranch: [String: Branch] = [:]
        for n in rawNodes {
            let id = str(n["id"]), label = shortLabel(str(n["label"]))
            guard !id.isEmpty, !label.isEmpty, !nodes.contains(where: { $0.id == id }) else { continue }
            let parent = str(n["parent"])
            if let b = Branch(rawValue: str(n["branch"]).lowercased()) { declaredBranch[id] = b }
            nodes.append(Node(id: id, label: label, branch: .problem, parent: parent.isEmpty ? nil : parent,
                              description: str(n["description"]), core: str(n["core"])))
        }
        let ids = Set(nodes.map(\.id))
        for i in nodes.indices where nodes[i].parent.map({ !ids.contains($0) || $0 == nodes[i].id }) == true {
            nodes[i].parent = nil
        }

        // A concept's branch is its own, else its nearest ancestor's.
        func branch(of id: String) -> Branch? {
            var seen = Set<String>(), cur: String? = id
            while let c = cur, seen.insert(c).inserted {
                if let b = declaredBranch[c] { return b }
                cur = nodes.first { $0.id == c }?.parent
            }
            return nil
        }
        nodes = nodes.compactMap { n in branch(of: n.id).map { var m = n; m.branch = $0; return m } }

        // One main concept per branch; the rest hang under it.
        var roots: [Branch: String] = [:]
        for n in nodes where n.parent == nil && roots[n.branch] == nil { roots[n.branch] = n.id }
        guard Branch.allCases.allSatisfy({ roots[$0] != nil }) else { return nil }
        let rootIds = Set(roots.values)
        for i in nodes.indices {
            let n = nodes[i]
            guard !rootIds.contains(n.id) else { continue }
            let parentNode = n.parent.flatMap { p in nodes.first { $0.id == p } }
            // Orphans, other parentless concepts and links across branches go under the branch root.
            if parentNode == nil || parentNode?.branch != n.branch { nodes[i].parent = roots[n.branch] }
        }
        // Break cycles: a concept whose ancestors never reach a root goes under its branch root.
        for i in nodes.indices where !rootIds.contains(nodes[i].id) {
            var seen = Set<String>(), cur = nodes[i].parent
            while let c = cur, !rootIds.contains(c), seen.insert(c).inserted { cur = nodes.first { $0.id == c }?.parent }
            if cur == nil || !rootIds.contains(cur!) { nodes[i].parent = roots[nodes[i].branch] }
        }

        let kept = Set(nodes.map(\.id))
        var links: [Link] = []
        for l in (obj["links"] as? [[String: Any]]) ?? [] {
            let from = str(l["from"]), to = str(l["to"])
            guard kept.contains(from), kept.contains(to), from != to else { continue }
            let tree = nodes.contains { ($0.id == from && $0.parent == to) || ($0.id == to && $0.parent == from) }
            let dup = links.contains { Set([$0.from, $0.to]) == Set([from, to]) }
            if !tree && !dup { links.append(Link(from: from, to: to, label: shortLabel(str(l["label"])))) }
        }
        return MindMap(nodes: nodes, links: links)
    }
}
