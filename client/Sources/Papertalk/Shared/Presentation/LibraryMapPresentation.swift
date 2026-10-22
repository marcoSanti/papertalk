// The library map: a library's papers as one graph, joined where their mind maps connect and
// grouped into clusters, with its layout (papers on a ring, dragged to rearrange) and wording.

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
    /// outside papers they connect to, so a cluster sits together on the ring.
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

/// Where each paper sits: the library's on one ring, spaced so the boxes don't touch (a single
/// paper in the middle), and outside papers on a ring around it. Papers the user dragged go
/// where they were dropped (`arranged`).
struct LibraryMapLayout: Equatable {
    /// Paper id → centre of its box, in points from the top-left.
    private(set) var positions: [String: MindMapLayout.Point] = [:]

    /// This layout with dragged papers (id → where dropped) moved, kept on the canvas if the
    /// window has shrunk since; unknown ids are ignored.
    func arranged(_ moved: [String: MindMapLayout.Point]) -> LibraryMapLayout {
        var l = self
        for (id, p) in moved where l.positions[id] != nil { l.positions[id] = dragged(from: p, dx: 0, dy: 0, scale: 1) }
        return l
    }

    /// Where a paper dragged from `start` by (`dx`, `dy`) screen points at `scale` lands, kept
    /// on the canvas.
    func dragged(from start: MindMapLayout.Point, dx: Double, dy: Double, scale: Double) -> MindMapLayout.Point {
        .init(x: min(width - Self.nodeWidth / 2, max(Self.nodeWidth / 2, start.x + dx / scale)),
              y: min(height - Self.nodeHeight / 2, max(Self.nodeHeight / 2, start.y + dy / scale)))
    }
    private(set) var width = 0.0, height = 0.0
    /// Paper box the layout leaves room for.
    static let nodeWidth = 190.0, nodeHeight = 70.0
    private static let minRadius = 200.0, ringGap = 240.0, margin = 40.0

    /// The layout on a canvas of at least `minWidth` × `minHeight` (the window's graph area):
    /// the rings stretch, wider or taller, to fill the room the papers don't need.
    init(_ map: LibraryMap, minWidth: Double = 0, minHeight: Double = 0) {
        func radius(_ n: Int) -> Double { Double(n) * (Self.nodeWidth + 30) / (2 * .pi) }
        let inner = map.members, outer = map.nodes.filter(\.isOutside)
        let r = inner.count <= 1 ? 0 : max(Self.minRadius, radius(inner.count))
        let r2 = outer.isEmpty ? r : max(r + Self.ringGap, radius(outer.count))
        width = max(minWidth, 2 * r2 + Self.nodeWidth + 2 * Self.margin)
        height = max(minHeight, 2 * r2 + Self.nodeHeight + 2 * Self.margin)
        // How far the outer ring can stretch each way; stretching only moves papers apart.
        let sx = r2 > 0 ? (width - Self.nodeWidth - 2 * Self.margin) / (2 * r2) : 1
        let sy = r2 > 0 ? (height - Self.nodeHeight - 2 * Self.margin) / (2 * r2) : 1
        // Start at the top and go clockwise; the outer ring starts half a step on.
        for (ring, radius, shift) in [(inner, r, 0.0), (outer, r2, 0.5)] {
            for (i, node) in ring.enumerated() {
                let a = -Double.pi / 2 + 2 * .pi * (Double(i) + shift) / Double(max(ring.count, 1))
                positions[node.id] = .init(x: width / 2 + sx * radius * cos(a), y: height / 2 + sy * radius * sin(a))
            }
        }
    }

    /// The zoom that shows the whole map in a `viewW` × `viewH` viewport, never above 100%.
    func fitScale(width viewW: Double, height viewH: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return max(MindMapLayout.minScale, min(1, viewW / width, viewH / height))
    }
}

/// The library map window's wording.
enum LibraryMapPresentation {
    /// The window's title.
    static func title(_ library: String) -> String { L("Paper connections — {0}", library) }
    /// The sidebar menu item and toolbar button that open it.
    static var open: String { L("Show Paper Connections") }
    static var openHelp: String { L("See how this library's papers connect through their mind maps") }
    /// The panel with nothing selected.
    static func overview(_ map: LibraryMap) -> String {
        LibraryPresentation.paperCount(map.members.count) + " · "
            + LibraryPresentation.count(map.edges.count, L("1 connected pair"), L("{0} connected pairs"))
    }
    static var hint: String { L("Click a paper or a line to see how they connect.") }
    /// Under the overview when nothing connects, saying why.
    static func emptyNote(_ map: LibraryMap) -> String? {
        guard map.edges.isEmpty else { return nil }
        return map.members.contains(where: \.hasMindMap)
            ? L("No connections yet. Papers connect when their mind maps share concepts.")
            : L("No paper here has a mind map yet. Create one from a paper's Manage menu.")
    }
    /// A paper's line in the panel, and a line's badge.
    static func linkCount(_ n: Int) -> String { LibraryPresentation.count(n, L("1 connection"), L("{0} connections")) }
    /// Under a paper with no map.
    static var noMindMap: String { L("No mind map yet") }
    static var openMindMap: String { L("Open mind map") }
    static var connectedPapers: String { L("Connected papers") }
    static var connectionsTitle: String { L("Connections") }
    /// A paper with no connected papers.
    static var noConnections: String { L("Not connected to other papers in this library.") }
    /// The button that undoes the user's dragging.
    static var resetArrangement: String { L("Put every paper back in place") }
    /// Above an outside paper's title.
    static var outsideHeading: String { L("Outside this library") }
}
