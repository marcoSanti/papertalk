import Foundation

/// Where every concept of a mind map sits: the paper in the centre, one
/// 120° sector per branch (problem up-left, method up-right, evidence down),
/// and each concept's sector shared among its children by how many concepts
/// they lead to. Rings move out until neighbours have room for their labels.
struct MindMapLayout: Equatable {
    struct Point: Equatable { var x: Double; var y: Double }
    struct Edge: Equatable, Identifiable {
        let from: String
        let to: String
        /// A link across branches (drawn dashed, with its label); otherwise a tree edge.
        let label: String?
        var id: String { from + "→" + to }
    }

    /// Edges that join two concepts (not the paper to a main concept): these can be selected.
    var selectableEdges: [Edge] { edges.filter { $0.from != Self.centerId } }

    /// How far each link bows, as a share of its length: positive away from
    /// the centre, negative towards it. Chosen so its label clears every node.
    private var bend: [String: Double] = [:]
    private static let bends = [0.3, 0.45, 0.6, 0.15, -0.3, -0.45]

    /// A link's curve control point: links bow sideways (away from the centre
    /// unless that puts the label on a node). nil for straight tree edges.
    func control(_ e: Edge) -> Point? {
        guard e.label != nil, let a = positions[e.from], let b = positions[e.to] else { return nil }
        let mid = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y, length = max(hypot(dx, dy), 1)
        var nx = -dy / length, ny = dx / length
        if let c = positions[Self.centerId], nx * (c.x - mid.x) + ny * (c.y - mid.y) > 0 { nx = -nx; ny = -ny }
        let f = bend[e.id] ?? Self.bends[0]
        return Point(x: mid.x + nx * f * length, y: mid.y + ny * f * length)
    }

    /// Whether a link label at `p` would cover a node.
    func labelOverlapsNode(_ p: Point) -> Bool {
        positions.values.contains {
            abs($0.x - p.x) < (Self.nodeWidth + Self.linkLabelWidth) / 2
                && abs($0.y - p.y) < (Self.nodeHeight + Self.linkLabelHeight) / 2
        }
    }

    /// Where an edge's handle sits: halfway along the line or curve.
    func handle(_ e: Edge) -> Point? {
        guard let a = positions[e.from], let b = positions[e.to] else { return nil }
        guard let k = control(e) else { return Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        return Point(x: 0.25 * a.x + 0.5 * k.x + 0.25 * b.x, y: 0.25 * a.y + 0.5 * k.y + 0.25 * b.y)
    }

    static let centerId = "§paper"
    /// Node box the layout leaves room for.
    static let nodeWidth = 150.0, nodeHeight = 56.0
    /// Room left for a link's label tag.
    static let linkLabelWidth = 110.0, linkLabelHeight = 24.0
    private static let firstRing = 200.0, ringGap = 175.0, margin = 24.0

    /// Concept id (and `centerId`) → centre of its node, in points from the top-left.
    private(set) var positions: [String: Point] = [:]
    private(set) var edges: [Edge] = []
    private(set) var width = 0.0, height = 0.0
    /// Depth of each concept: 1 for a branch's main concept.
    private(set) var depth: [String: Int] = [:]

    static let minScale = 0.3, maxScale = 2.0

    /// The zoom that shows the whole map in a `width` × `height` viewport
    /// (never enlarged past 100%, never below `minScale`).
    func fitScale(width viewW: Double, height viewH: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return max(Self.minScale, min(1, viewW / width, viewH / height))
    }

    static func clampScale(_ s: Double) -> Double { min(maxScale, max(minScale, s)) }

    /// Where the graph starts inside the scroll view at `scale`: after the
    /// padding, or centred when it's smaller than the viewport.
    private func origin(_ scale: Double, viewport: (width: Double, height: Double), padding: Double) -> Point {
        Point(x: max(padding, (viewport.width - width * scale) / 2), y: max(padding, (viewport.height - height * scale) / 2))
    }

    /// The point of the map (in layout units) under `anchor`, a point in the viewport.
    func mapPoint(under anchor: Point, offset: Point, scale: Double,
                  viewport: (width: Double, height: Double), padding: Double) -> Point {
        let o = origin(scale, viewport: viewport, padding: padding)
        return Point(x: (offset.x + anchor.x - o.x) / scale, y: (offset.y + anchor.y - o.y) / scale)
    }

    /// The scroll offset that keeps the map point under `anchor` (the pointer,
    /// or the viewport's centre) in place when zooming from `s0` to `s1`.
    func zoomedOffset(offset: Point, anchor: Point, from s0: Double, to s1: Double,
                      viewport: (width: Double, height: Double), padding: Double) -> Point {
        let g = mapPoint(under: anchor, offset: offset, scale: s0, viewport: viewport, padding: padding)
        let o1 = origin(s1, viewport: viewport, padding: padding)
        let maxX = max(0, width * s1 + 2 * padding - viewport.width)
        let maxY = max(0, height * s1 + 2 * padding - viewport.height)
        return Point(x: min(maxX, max(0, g.x * s1 + o1.x - anchor.x)),
                     y: min(maxY, max(0, g.y * s1 + o1.y - anchor.y)))
    }

    /// The scroll offset after dragging the map by (`dx`, `dy`) from `start`:
    /// the content follows the pointer, and stops at its edges.
    static func panned(from start: Point, dx: Double, dy: Double,
                       content: (width: Double, height: Double), viewport: (width: Double, height: Double)) -> Point {
        Point(x: min(max(0, content.width - viewport.width), max(0, start.x - dx)),
              y: min(max(0, content.height - viewport.height), max(0, start.y - dy)))
    }

    static func sectorCenter(_ b: MindMap.Branch) -> Double {
        switch b {
        case .problem: return 210
        case .method: return 330
        case .evidence: return 90
        }
    }

    init(_ map: MindMap) {
        var angle: [String: Double] = [:]
        func weight(_ id: String) -> Double {
            let kids = map.children(of: id)
            return kids.isEmpty ? 1 : kids.map { weight($0.id) }.reduce(0, +)
        }
        func place(_ id: String, from a0: Double, to a1: Double, depth d: Int) {
            angle[id] = (a0 + a1) / 2
            depth[id] = d
            let kids = map.children(of: id)
            let total = kids.map { weight($0.id) }.reduce(0, +)
            var start = a0
            for k in kids {
                let span = (a1 - a0) * weight(k.id) / total
                place(k.id, from: start, to: start + span, depth: d + 1)
                start += span
            }
        }
        for b in MindMap.Branch.allCases {
            guard let root = map.root(b) else { continue }
            let c = Self.sectorCenter(b)
            place(root.id, from: c - 56, to: c + 56, depth: 1)
        }

        // Each ring is far enough out that the closest two of its nodes are a label apart.
        let maxDepth = depth.values.max() ?? 0
        var radius: [Int: Double] = [:]
        for d in 1...max(1, maxDepth) {
            let angles = depth.filter { $0.value == d }.compactMap { angle[$0.key] }.sorted()
            var gap = 360.0
            for (a, b) in zip(angles, angles.dropFirst()) { gap = min(gap, b - a) }
            if angles.count > 1 { gap = min(gap, angles[0] + 360 - angles[angles.count - 1]) }
            let needed = (Self.nodeWidth + 30) / (max(gap, 0.5) * .pi / 180)
            let previous = d == 1 ? 0 : (radius[d - 1] ?? 0) + Self.ringGap
            radius[d] = max(d == 1 ? Self.firstRing : previous, needed)
        }

        var raw: [String: Point] = [Self.centerId: Point(x: 0, y: 0)]
        for (id, a) in angle {
            let r = radius[depth[id] ?? 1] ?? Self.firstRing
            raw[id] = Point(x: r * cos(a * .pi / 180), y: r * sin(a * .pi / 180))
        }
        edges = MindMap.Branch.allCases.compactMap { map.root($0) }.map { Edge(from: Self.centerId, to: $0.id, label: nil) }
            + map.nodes.compactMap { n in n.parent.map { Edge(from: $0, to: n.id, label: nil) } }
            + map.links.map { Edge(from: $0.from, to: $0.to, label: $0.label) }

        // The canvas holds every node, and every link's curve and label: a link
        // bows outward, and its furthest point is its handle.
        positions = raw
        for e in edges where e.label != nil {
            bend[e.id] = Self.bends.first { f in
                bend[e.id] = f
                return handle(e).map { !labelOverlapsNode($0) } ?? true
            } ?? Self.bends[0]
        }
        let handles = edges.filter { $0.label != nil }.compactMap { handle($0) }
        let xs = raw.values.map { [$0.x - Self.nodeWidth / 2, $0.x + Self.nodeWidth / 2] }.flatMap { $0 }
            + handles.map { [$0.x - Self.linkLabelWidth / 2, $0.x + Self.linkLabelWidth / 2] }.flatMap { $0 }
        let ys = raw.values.map { [$0.y - Self.nodeHeight / 2, $0.y + Self.nodeHeight / 2] }.flatMap { $0 }
            + handles.map { [$0.y - Self.linkLabelHeight / 2, $0.y + Self.linkLabelHeight / 2] }.flatMap { $0 }
        let left = (xs.min() ?? 0) - Self.margin, top = (ys.min() ?? 0) - Self.margin
        positions = raw.mapValues { Point(x: $0.x - left, y: $0.y - top) }
        width = (xs.max() ?? 0) + Self.margin - left
        height = (ys.max() ?? 0) + Self.margin - top
    }
}

/// The mind map sheet's wording and the side panel's content.
enum MindMapPresentation {
    static let heading = "Mind map"
    static let paperHeading = "The paper"
    static let mainConceptsTitle = "Main concepts"
    static let hint = "Click a concept or a connection to see it here; click the paper to come back."
    static let noSummary = "This map was drawn before maps had a summary. Redraw mind map (under Manage) adds one."

    static func summary(_ map: MindMap) -> String { map.summary ?? noSummary }
    static let coreTitle = "Core"
    static let descriptionTitle = "What it is"
    static let connectionsTitle = "Connections"
    static let missingMessage = "Couldn't open the mind map. Create it again from Manage."

    static func branchTitle(_ b: MindMap.Branch) -> String {
        switch b {
        case .problem: return "The problem"
        case .method: return "The approach"
        case .evidence: return "The demonstration"
        }
    }

    static func branchIcon(_ b: MindMap.Branch) -> String {
        switch b {
        case .problem: return "exclamationmark.triangle"
        case .method: return "gearshape.2"
        case .evidence: return "checkmark.seal"
        }
    }

    struct Connection: Equatable, Identifiable {
        let id: String
        let label: String
        /// How it relates to the selected concept ("Part of", "Includes", or the link's label).
        let relation: String
    }

    /// The concepts next to `id`: its parent, its parts, then links across branches.
    static func connections(_ map: MindMap, of id: String) -> [Connection] {
        guard let node = map.node(id) else { return [] }
        var out: [Connection] = []
        if let p = node.parent.flatMap(map.node) { out.append(Connection(id: p.id, label: p.label, relation: "Part of")) }
        out += map.children(of: id).map { Connection(id: $0.id, label: $0.label, relation: "Includes") }
        for l in map.links where l.from == id || l.to == id {
            let other = l.from == id ? l.to : l.from
            if let n = map.node(other) { out.append(Connection(id: n.id, label: n.label, relation: l.label.isEmpty ? "Linked" : l.label)) }
        }
        return out
    }

    static let connectionHeading = "Connection"

    /// A selected edge: the two concepts it joins, top to bottom, and how.
    struct EdgeDetail: Equatable {
        let top: MindMap.Node
        let bottom: MindMap.Node
        let relation: String
    }

    /// Tree edges read "includes" from the broader concept down; links keep
    /// their label and direction.
    static func edgeDetail(_ map: MindMap, _ edge: MindMapLayout.Edge) -> EdgeDetail? {
        guard let a = map.node(edge.from), let b = map.node(edge.to) else { return nil }
        guard let label = edge.label else { return EdgeDetail(top: a, bottom: b, relation: "includes") }
        return EdgeDetail(top: a, bottom: b, relation: label.isEmpty ? "linked to" : label)
    }

    static func edgeHelp(_ d: EdgeDetail) -> String { "\(d.top.label) \(d.relation) \(d.bottom.label)" }

    /// A node's tier, for its look: the paper, a main concept, or a detail.
    enum Tier { case paper, main, detail }
    static func tier(_ layout: MindMapLayout, _ id: String) -> Tier {
        id == MindMapLayout.centerId ? .paper : layout.depth[id] == 1 ? .main : .detail
    }
}
