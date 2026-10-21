// The mind map model (`mindmap.json`) and the lenient parser that turns the LLM's reply into
// one: concepts in a tree under three branches, plus labelled links across them.

import Foundation

/// A paper's mind map ("mappa mentale"): its key concepts as a tree under
/// three pillars (the problem, the method, the demonstration), plus a few
/// links across branches. Saved as `mindmap.json` beside the paper.
struct MindMap: Codable, Equatable {
    /// The three pillars every map is built around: what the paper tackles, how, and what shows it works.
    enum Branch: String, Codable, CaseIterable {
        case problem, method, evidence
    }

    /// One concept. Ids are the LLM's own, unique within a map.
    struct Node: Codable, Equatable, Identifiable {
        /// The LLM's id for the concept; parents and links refer to it.
        var id: String
        /// The concept's name, short enough to label a node.
        var label: String
        /// Inherited from the nearest ancestor when the LLM left it out.
        var branch: Branch
        /// nil for the branch's main concept.
        var parent: String?
        /// What the concept is, in a few sentences.
        var description: String
        /// Its key feature, finding or number, in one sentence.
        var core: String
    }

    /// A relation between concepts of different branches (tree edges aren't links).
    struct Link: Codable, Equatable {
        var from: String
        var to: String
        /// How `from` relates to `to`, read in that order (e.g. "measured by").
        var label: String
    }

    /// Every concept, the three branch roots included.
    var nodes: [Node]
    /// Cross-branch relations; duplicates and tree edges are dropped by `parse`.
    var links: [Link]
    /// The paper in a few plain sentences (its abstract restated). nil in maps
    /// drawn before summaries, which still decode.
    var summary: String? = nil

    /// The branch's main concept.
    func root(_ branch: Branch) -> Node? { nodes.first { $0.branch == branch && $0.parent == nil } }
    /// The concept with this id, if any.
    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    /// A concept's direct parts, in the order the LLM listed them.
    func children(of id: String) -> [Node] { nodes.filter { $0.parent == id } }

    /// Whether every pillar is broken down into at least two parts.
    var isExpanded: Bool {
        Branch.allCases.allSatisfy { b in root(b).map { children(of: $0.id).count >= 2 } ?? false }
    }

    /// Longest node label, in characters; longer ones are cut by `shortLabel`.
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
        let summary = str(obj["summary"])
        return MindMap(nodes: nodes, links: links, summary: summary.isEmpty ? nil : summary)
    }
}

// MARK: - Editing

/// The edits the mind map window makes. Each keeps the map valid: three branch roots, a tree
/// under each, and links only between existing concepts that aren't already joined.
extension MindMap {
    /// Whether `id` and everything under it can go: every concept but the three branch roots.
    func canDelete(_ id: String) -> Bool { node(id).map { $0.parent != nil } ?? false }

    /// `id` and every concept under it.
    func subtree(_ id: String) -> Set<String> {
        var out: Set<String> = [id], queue = [id]
        while let next = queue.popLast() {
            for c in children(of: next) where out.insert(c.id).inserted { queue.append(c.id) }
        }
        return out
    }

    /// Whether `a` and `b` are already joined, by the tree or by a link.
    func joined(_ a: String, _ b: String) -> Bool {
        nodes.contains { ($0.id == a && $0.parent == b) || ($0.id == b && $0.parent == a) }
            || links.contains { Set([$0.from, $0.to]) == Set([a, b]) }
    }

    /// Add a concept under `parent`, in its branch. Returns the new id, nil if `parent` doesn't exist.
    @discardableResult
    mutating func addNode(under parent: String, label: String) -> String? {
        guard let p = node(parent) else { return nil }
        var n = nodes.count + 1
        while node("n\(n)") != nil { n += 1 }
        let id = "n\(n)"
        nodes.append(Node(id: id, label: Self.shortLabel(label), branch: p.branch, parent: parent, description: "", core: ""))
        return id
    }

    /// Change a concept's text. An empty label keeps the old one.
    mutating func editNode(_ id: String, label: String, core: String, description: String) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        let short = Self.shortLabel(label)
        if !short.isEmpty { nodes[i].label = short }
        nodes[i].core = core.trimmingCharacters(in: .whitespacesAndNewlines)
        nodes[i].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Delete a concept with everything under it, and their links. Branch roots stay.
    mutating func deleteNode(_ id: String) {
        guard canDelete(id) else { return }
        let gone = subtree(id)
        nodes.removeAll { gone.contains($0.id) }
        links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
    }

    /// Where `id` can be moved: any concept outside its own subtree, except its current parent.
    func parentOptions(for id: String) -> [Node] {
        guard canDelete(id) else { return [] }
        let own = subtree(id)
        return nodes.filter { !own.contains($0.id) && $0.id != node(id)?.parent }
    }

    /// Move `id` (with its subtree) under `parent`; it takes the new branch. A link that becomes
    /// the tree edge is dropped.
    mutating func move(_ id: String, under parent: String) {
        guard let p = node(parent), parentOptions(for: id).contains(where: { $0.id == parent }) else { return }
        let moved = subtree(id)
        for i in nodes.indices where moved.contains(nodes[i].id) { nodes[i].branch = p.branch }
        if let i = nodes.firstIndex(where: { $0.id == id }) { nodes[i].parent = parent }
        links.removeAll { Set([$0.from, $0.to]) == Set([id, parent]) }
    }

    /// Concepts `id` can be linked to: any other concept it isn't already joined to.
    func linkTargets(from id: String) -> [Node] {
        nodes.filter { $0.id != id && !joined(id, $0.id) }
    }

    /// Link two concepts. Returns false when they're the same, missing, or already joined.
    @discardableResult
    mutating func addLink(from: String, to: String, label: String) -> Bool {
        guard node(from) != nil, linkTargets(from: from).contains(where: { $0.id == to }) else { return false }
        links.append(Link(from: from, to: to, label: Self.shortLabel(label)))
        return true
    }

    /// Change a link's label.
    mutating func editLink(from: String, to: String, label: String) {
        guard let i = links.firstIndex(where: { $0.from == from && $0.to == to }) else { return }
        links[i].label = Self.shortLabel(label)
    }

    /// Remove a link.
    mutating func deleteLink(from: String, to: String) {
        links.removeAll { $0.from == from && $0.to == to }
    }
}
