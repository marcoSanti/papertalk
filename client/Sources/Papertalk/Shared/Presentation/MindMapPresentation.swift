// The mind map's geometry and wording: `MindMapLayout` places every concept on rings around
// the paper and handles zoom and pan; `MindMapPresentation` words the window and its side panel.

import Foundation

/// Where every concept of a mind map sits: the paper in the centre, one
/// 120° sector per branch (problem up-left, method up-right, evidence down),
/// and each concept's sector shared among its children by how many concepts
/// they lead to. Rings move out until neighbours have room for their labels.
struct MindMapLayout: Equatable {
    /// A position in layout points.
    struct Point: Equatable { var x: Double; var y: Double }
    /// A line between two nodes: a tree edge or a cross-branch link.
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
    /// the centre, negative towards it. Chosen so its curve and label clear every node.
    private var bend: [String: Double] = [:]
    private static let bends = [0.3, 0.45, 0.6, 0.15, -0.3, -0.45, 0.8, 1.0, -0.6]

    /// What the user has dragged in the window: concepts to new places, and edges' handles off
    /// their midpoint. Kept apart from the computed layout so a redraw after an edit reapplies it.
    struct Arrangement: Equatable {
        var nodes: [String: Point] = [:]
        /// Edge id → its handle's offset from the midpoint between its two ends.
        var handles: [String: Point] = [:]
        var isEmpty: Bool { nodes.isEmpty && handles.isEmpty }
    }
    private var handleOffsets: [String: Point] = [:]

    /// This layout with the user's arrangement applied; concepts no longer on the map are ignored.
    func arranged(_ a: Arrangement) -> MindMapLayout {
        var l = self
        for (id, p) in a.nodes where l.positions[id] != nil { l.positions[id] = p }
        l.handleOffsets = a.handles
        return l
    }

    /// Where something dragged from `start` by (`dx`, `dy`) screen points at `scale` lands,
    /// kept on the canvas with room for a `w` × `h` box around it.
    func dragged(from start: Point, dx: Double, dy: Double, scale: Double,
                 w: Double = nodeWidth, h: Double = nodeHeight) -> Point {
        Point(x: min(width - w / 2, max(w / 2, start.x + dx / scale)),
              y: min(height - h / 2, max(h / 2, start.y + dy / scale)))
    }

    /// How far `filling` moved the map to centre it on a bigger canvas (zero otherwise).
    private(set) var shift = Point(x: 0, y: 0)

    /// This layout on a canvas of at least `w` × `h` (the window, in layout points), the map
    /// centred on it, so concepts can be dragged anywhere in the window.
    func filling(width w: Double, height h: Double) -> MindMapLayout {
        let dx = max(0, (w - width) / 2), dy = max(0, (h - height) / 2)
        guard dx > 0 || dy > 0 else { return self }
        var l = self
        l.positions = positions.mapValues { Point(x: $0.x + dx, y: $0.y + dy) }
        l.width = max(width, w)
        l.height = max(height, h)
        l.shift = Point(x: shift.x + dx, y: shift.y + dy)
        return l
    }

    /// The handle offset that puts `e`'s handle at `p`.
    func handleOffset(_ e: Edge, at p: Point) -> Point? {
        guard let a = positions[e.from], let b = positions[e.to] else { return nil }
        return Point(x: p.x - (a.x + b.x) / 2, y: p.y - (a.y + b.y) / 2)
    }

    /// An edge's curve control point: where the user dragged its handle, else links bow
    /// sideways (away from the centre unless that puts the label on a node). nil for straight edges.
    func control(_ e: Edge) -> Point? {
        guard let a = positions[e.from], let b = positions[e.to] else { return nil }
        let mid = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // The handle is halfway along the curve, so the control point sits twice as far out.
        if let o = handleOffsets[e.id] { return Point(x: mid.x + 2 * o.x, y: mid.y + 2 * o.y) }
        guard e.label != nil else { return nil }
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

    /// How many nodes a link's curve (at its current bend) runs through, plus how many nodes
    /// and earlier `labels` its label covers: 0 is a clean link.
    private func collisions(_ e: Edge, labels: [Point]) -> Int {
        guard let a = positions[e.from], let b = positions[e.to], let k = control(e), let h = handle(e) else { return 0 }
        let curve = stride(from: 0.0, through: 1.0, by: 0.025).map { t in
            Point(x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * k.x + t * t * b.x,
                  y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * k.y + t * t * b.y)
        }
        let crossed = positions.filter { id, c in
            id != e.from && id != e.to
                && curve.contains { abs($0.x - c.x) < Self.nodeWidth / 2 + 4 && abs($0.y - c.y) < Self.nodeHeight / 2 + 4 }
        }.count
        let covered = labels.filter { abs($0.x - h.x) < Self.linkLabelWidth && abs($0.y - h.y) < Self.linkLabelHeight + 4 }.count
        return crossed + covered + (labelOverlapsNode(h) ? 1 : 0)
    }

    /// Where an edge's handle sits: halfway along the line or curve.
    func handle(_ e: Edge) -> Point? {
        guard let a = positions[e.from], let b = positions[e.to] else { return nil }
        guard let k = control(e) else { return Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        return Point(x: 0.25 * a.x + 0.5 * k.x + 0.25 * b.x, y: 0.25 * a.y + 0.5 * k.y + 0.25 * b.y)
    }

    /// The paper's node id; "§" keeps it from clashing with the LLM's ids.
    static let centerId = "§paper"
    /// The node id of another paper's concept, shown on the outer ring.
    static func externalId(paperId: String, nodeId: String) -> String { "§ext:\(paperId):\(nodeId)" }
    /// Whether `id` is another paper's concept.
    static func isExternal(_ id: String) -> Bool { id.hasPrefix("§ext:") }
    /// Node box the layout leaves room for.
    static let nodeWidth = 172.0, nodeHeight = 64.0
    /// Room left for a link's label tag.
    static let linkLabelWidth = 130.0, linkLabelHeight = 26.0
    private static let firstRing = 180.0, ringGap = 190.0, margin = 24.0

    /// Concept id (and `centerId`) → centre of its node, in points from the top-left.
    private(set) var positions: [String: Point] = [:]
    private(set) var edges: [Edge] = []
    private(set) var width = 0.0, height = 0.0
    /// Depth of each concept: 1 for a branch's main concept.
    private(set) var depth: [String: Int] = [:]

    /// Zoom limits.
    static let minScale = 0.3, maxScale = 2.0

    /// The zoom that shows the whole map in a `width` × `height` viewport
    /// (never enlarged past 100%, never below `minScale`).
    func fitScale(width viewW: Double, height viewH: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return max(Self.minScale, min(1, viewW / width, viewH / height))
    }

    /// A zoom within the limits.
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

    /// Each branch's direction, in degrees (0 is right, 90 down).
    static func sectorCenter(_ b: MindMap.Branch) -> Double {
        switch b {
        case .problem: return 210
        case .method: return 330
        case .evidence: return 90
        }
    }

    /// Lays the map out: angles by sector share, then rings far enough apart for the labels.
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

        // Each ring is far enough out that neighbouring boxes clear each other, side by side
        // (at the top and bottom) or stacked (at the sides), whichever comes first.
        let maxDepth = depth.values.max() ?? 0
        var radius: [Int: Double] = [:]
        for d in 1...max(1, maxDepth) {
            let angles = depth.filter { $0.value == d }.compactMap { angle[$0.key] }.sorted()
            var needed = 0.0
            for (a, b) in zip(angles, angles.dropFirst() + angles.prefix(angles.count > 2 ? 1 : 0)) {
                let dx = abs(cos(a * .pi / 180) - cos(b * .pi / 180)), dy = abs(sin(a * .pi / 180) - sin(b * .pi / 180))
                needed = max(needed, min((Self.nodeWidth + 24) / max(dx, 1e-3), (Self.nodeHeight + 16) / max(dy, 1e-3)))
            }
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

        // Other papers' concepts sit on a ring of their own outside the map, each towards the
        // concepts it connects to, pushed apart so their boxes don't touch.
        var outer: [String: [String]] = [:]
        for l in map.externalLinks where angle[l.from] != nil {
            outer[Self.externalId(paperId: l.paperId, nodeId: l.nodeId), default: []].append(l.from)
            edges.append(Edge(from: l.from, to: Self.externalId(paperId: l.paperId, nodeId: l.nodeId), label: l.label))
        }
        if !outer.isEmpty {
            let step = Self.nodeWidth + 30
            let r = max((radius.values.max() ?? Self.firstRing) + Self.ringGap, Double(outer.count) * step / (2 * .pi))
            let gap = step / r * 180 / .pi
            var placed = outer.map { id, froms -> (String, Double) in
                let x = froms.reduce(0) { $0 + cos((angle[$1] ?? 0) * .pi / 180) }
                let y = froms.reduce(0) { $0 + sin((angle[$1] ?? 0) * .pi / 180) }
                return (id, atan2(y, x) * 180 / .pi)
            }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            for i in placed.indices.dropFirst() where placed[i].1 < placed[i - 1].1 + gap {
                placed[i].1 = placed[i - 1].1 + gap
            }
            for (id, a) in placed { raw[id] = Point(x: r * cos(a * .pi / 180), y: r * sin(a * .pi / 180)) }
        }

        // The canvas holds every node, and every link's curve and label: a link
        // bows outward, and its furthest point is its handle.
        // Each link takes the first bend that runs clear of the nodes and the labels already
        // placed, or failing that the one that hits the fewest.
        positions = raw
        var labels: [Point] = []
        for e in edges where e.label != nil {
            var best = (f: Self.bends[0], hits: Int.max)
            for f in Self.bends where best.hits > 0 {
                bend[e.id] = f
                let hits = collisions(e, labels: labels)
                if hits < best.hits { best = (f, hits) }
            }
            bend[e.id] = best.f
            if let h = handle(e) { labels.append(h) }
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
    /// The window's title.
    static var heading: String { L("Mind map") }
    /// The side panel's heading when the paper is selected.
    static var paperHeading: String { L("The paper") }
    /// Above the three branches in the paper's panel.
    static var mainConceptsTitle: String { L("Main concepts") }
    /// How to use the map, under the summary.
    static var hint: String { L("Click a concept or a connection to see it here; click the paper to come back.") }
    /// Shown for maps saved before summaries existed.
    static var noSummary: String { L("This map was drawn before maps had a summary. Redraw mind map (under Manage) adds one.") }

    /// The paper's summary, or the note that the map predates them.
    static func summary(_ map: MindMap) -> String { map.summary ?? noSummary }
    /// Side panel section titles for a selected concept.
    static var coreTitle: String { L("Core") }
    static var descriptionTitle: String { L("What it is") }
    static var connectionsTitle: String { L("Connections") }
    /// The Delete concept button's tooltip: the three main concepts hold the map up and can't go.
    static func deleteHelp(_ canDelete: Bool) -> String {
        canDelete ? L("Delete this concept, everything under it and its connections")
                  : L("The three main concepts can't be deleted; change their text instead.")
    }
    /// When the map's file can't be read.
    static var missingMessage: String { L("Couldn't open the mind map. Create it again from Manage.") }

    /// Each branch's name.
    static func branchTitle(_ b: MindMap.Branch) -> String {
        switch b {
        case .problem: return L("The problem")
        case .method: return L("The approach")
        case .evidence: return L("The demonstration")
        }
    }

    /// Each branch's SF Symbol.
    static func branchIcon(_ b: MindMap.Branch) -> String {
        switch b {
        case .problem: return "exclamationmark.triangle"
        case .method: return "gearshape.2"
        case .evidence: return "checkmark.seal"
        }
    }

    /// A concept next to the selected one, in the side panel.
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
        if let p = node.parent.flatMap(map.node) { out.append(Connection(id: p.id, label: p.label, relation: L("Part of"))) }
        out += map.children(of: id).map { Connection(id: $0.id, label: $0.label, relation: L("Includes")) }
        for l in map.links where l.from == id || l.to == id {
            let other = l.from == id ? l.to : l.from
            if let n = map.node(other) { out.append(Connection(id: n.id, label: n.label, relation: l.label.isEmpty ? L("Linked") : l.label)) }
        }
        out += map.externalLinks.filter { $0.from == id }.map {
            Connection(id: MindMapLayout.externalId(paperId: $0.paperId, nodeId: $0.nodeId), label: $0.nodeLabel, relation: $0.label)
        }
        return out
    }

    /// The side panel's heading when an edge is selected.
    static var connectionHeading: String { L("Connection") }

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
        guard let label = edge.label else { return EdgeDetail(top: a, bottom: b, relation: L("includes")) }
        return EdgeDetail(top: a, bottom: b, relation: label.isEmpty ? L("linked to") : label)
    }

    /// An edge's tooltip, read as a sentence: "Attention includes Softmax".
    static func edgeHelp(_ d: EdgeDetail) -> String { "\(d.top.label) \(d.relation) \(d.bottom.label)" }

    /// A node's tier, for its look: the paper, a main concept, a detail, or another paper's concept.
    enum Tier { case paper, main, detail, external }
    /// Which tier a node is in.
    static func tier(_ layout: MindMapLayout, _ id: String) -> Tier {
        if MindMapLayout.isExternal(id) { return .external }
        return id == MindMapLayout.centerId ? .paper : layout.depth[id] == 1 ? .main : .detail
    }

    /// Another paper's concept on the map: which paper, the concept, and how this map's concepts
    /// connect to it.
    struct ExternalNode: Equatable {
        let paperId: String
        let paperTitle: String
        /// The concept's id in the other paper's map.
        let nodeId: String
        let label: String
        /// This map's concepts that connect to it, with how.
        let connections: [Connection]
    }

    /// The other paper's concept drawn as `id`, nil if `id` isn't one.
    static func external(_ map: MindMap, _ id: String) -> ExternalNode? {
        let links = map.externalLinks.filter { MindMapLayout.externalId(paperId: $0.paperId, nodeId: $0.nodeId) == id }
        guard let first = links.first else { return nil }
        let connections = links.compactMap { l in map.node(l.from).map { Connection(id: $0.id, label: $0.label, relation: l.label) } }
        return ExternalNode(paperId: first.paperId, paperTitle: first.paperTitle, nodeId: first.nodeId, label: first.nodeLabel, connections: connections)
    }

    /// The side panel's heading for another paper's concept.
    static var externalHeading: String { L("In another paper") }
    /// The button that opens the other paper's mind map.
    static var openOtherMap: String { L("Open its mind map") }
}
