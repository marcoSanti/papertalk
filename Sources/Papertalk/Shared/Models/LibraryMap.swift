// The library map's graph: a library's papers joined where their mind maps connect, in clusters.

import Foundation

/// A library's papers and how their mind maps connect: one edge per connected pair of papers,
/// holding every concept-to-concept connection between them. Built from the connections the
/// mind maps already store (`MindMap.external`), so drawing it calls no LLM.
struct LibraryMap: Equatable {
    /// A paper on the map.
    struct Node: Equatable, Identifiable {
        let id: String
        let title: String
        let hasMindMap: Bool
        /// A paper in another library (or none) that this library's papers connect to.
        var isOutside = false
        /// The cluster of library papers it's connected to, biggest first; nil for a paper
        /// connected to no other library paper, and for outside papers.
        var cluster: Int?
    }

    /// One concept connection between two papers, read from `a`'s concept to `b`'s.
    struct Link: Equatable, Identifiable {
        let fromLabel: String
        let toLabel: String
        let label: String
        var id: String { fromLabel + "→" + toLabel + ":" + label }
    }

    /// Two connected papers (`a` < `b`) and their concept connections.
    struct Edge: Equatable, Identifiable {
        let a: String
        let b: String
        let links: [Link]
        var id: String { a + "↔" + b }
    }

    /// The library's papers cluster by cluster (each by title, unclustered ones last), then the
    /// outside papers they connect to, so a cluster starts together on the ring.
    let nodes: [Node]
    /// The library's own papers.
    var members: [Node] { nodes.filter { !$0.isOutside } }
    /// Connected pairs, most connections first.
    let edges: [Edge]

    /// The graph of `papers` from their saved `maps` (paper id → map). Connections to `outside`
    /// papers are kept, and those papers added, only when they connect; connections to anything
    /// else are left out. Each one, stored on both maps, is counted once.
    init(papers: [Paper], maps: [String: MindMap], outside: [Paper] = []) {
        let mine = Set(papers.map(\.id))
        let linked = Set(maps.filter { mine.contains($0.key) }.values.flatMap { $0.externalLinks.map(\.paperId) })
        let others = outside.filter { !mine.contains($0.id) && linked.contains($0.id) }
        let ids = mine.union(others.map(\.id))
        func byTitle(_ a: Node, _ b: Node) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }
        let members = papers.map { Node(id: $0.id, title: $0.displayTitle, hasMindMap: maps[$0.id] != nil) }.sorted(by: byTitle)
        let outsiders = others.map { Node(id: $0.id, title: $0.displayTitle, hasMindMap: $0.hasMindMap == true, isOutside: true) }.sorted(by: byTitle)
        var pairs: [String: (a: String, b: String, links: [Link], seen: Set<String>)] = [:]
        for (pid, map) in maps.sorted(by: { $0.key < $1.key }) where mine.contains(pid) {
            for l in map.externalLinks where l.paperId != pid && ids.contains(l.paperId) {
                let here = map.node(l.from)?.label ?? l.from
                let forward = pid < l.paperId
                let (a, b) = forward ? (pid, l.paperId) : (l.paperId, pid)
                // Both sides store the connection: key it by its concepts, in a-to-b order.
                let key = forward ? "\(l.from)|\(l.nodeId)" : "\(l.nodeId)|\(l.from)"
                var pair = pairs["\(a)|\(b)"] ?? (a, b, [], [])
                guard pair.seen.insert(key).inserted else { continue }
                pair.links.append(forward ? Link(fromLabel: here, toLabel: l.nodeLabel, label: l.label)
                                          : Link(fromLabel: l.nodeLabel, toLabel: here, label: l.label))
                pairs["\(a)|\(b)"] = pair
            }
        }
        edges = pairs.values.map { Edge(a: $0.a, b: $0.b, links: $0.links) }
            .sorted { $0.links.count != $1.links.count ? $0.links.count > $1.links.count : $0.id < $1.id }

        // Clusters: library papers joined by lines among themselves (outside papers don't join them).
        var root = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.id) })
        func find(_ id: String) -> String { var r = id; while let up = root[r], up != r { r = up }; return r }
        for e in edges where mine.contains(e.a) && mine.contains(e.b) { root[find(e.a)] = find(e.b) }
        let groups = Dictionary(grouping: members, by: { find($0.id) }).values.filter { $0.count > 1 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : byTitle($0[0], $1[0]) }
        var clustered: [Node] = []
        for (i, group) in groups.enumerated() { clustered += group.map { var n = $0; n.cluster = i; return n } }
        nodes = clustered + members.filter { m in !clustered.contains { $0.id == m.id } } + outsiders
    }

    /// The node with this id.
    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    /// The line `id`, if it's on the map.
    func edge(_ id: String) -> Edge? { edges.first { $0.id == id } }
    /// The edges touching paper `id`.
    func edges(of id: String) -> [Edge] { edges.filter { $0.a == id || $0.b == id } }
    /// The paper at the other end of `edge` from `id`.
    func other(_ edge: Edge, from id: String) -> Node? { node(edge.a == id ? edge.b : edge.a) }
    /// The cluster `edge` lies in (both ends in it), nil for lines to outside papers.
    func cluster(of edge: Edge) -> Int? {
        let c = node(edge.a)?.cluster
        return c != nil && c == node(edge.b)?.cluster ? c : nil
    }
    /// Whether `edge` reaches a paper outside the library (drawn grey).
    func isOutside(_ edge: Edge) -> Bool { node(edge.a)?.isOutside == true || node(edge.b)?.isOutside == true }
}
