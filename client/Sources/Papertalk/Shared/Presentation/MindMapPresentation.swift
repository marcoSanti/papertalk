import Foundation

/// Where every concept of a mind map sits: the paper in the centre, one
/// 120° sector per branch (problem up-left, method up-right, evidence down),
/// and each concept's sector shared among its children by how many concepts
/// they lead to. Rings move out until neighbours have room for their labels.
struct MindMapLayout: Equatable {
    struct Point: Equatable { var x: Double; var y: Double }
    struct Edge: Equatable {
        let from: String
        let to: String
        /// A link across branches (drawn dashed, with its label); otherwise a tree edge.
        let label: String?
    }

    static let centerId = "§paper"
    /// Node box the layout leaves room for.
    static let nodeWidth = 150.0, nodeHeight = 56.0
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
        let xs = raw.values.map(\.x), ys = raw.values.map(\.y)
        let left = (xs.min() ?? 0) - Self.nodeWidth / 2 - Self.margin
        let top = (ys.min() ?? 0) - Self.nodeHeight / 2 - Self.margin
        positions = raw.mapValues { Point(x: $0.x - left, y: $0.y - top) }
        width = (xs.max() ?? 0) + Self.nodeWidth / 2 + Self.margin - left
        height = (ys.max() ?? 0) + Self.nodeHeight / 2 + Self.margin - top

        edges = MindMap.Branch.allCases.compactMap { map.root($0) }.map { Edge(from: Self.centerId, to: $0.id, label: nil) }
            + map.nodes.compactMap { n in n.parent.map { Edge(from: $0, to: n.id, label: nil) } }
            + map.links.map { Edge(from: $0.from, to: $0.to, label: $0.label) }
    }
}

/// The mind map sheet's wording and the side panel's content.
enum MindMapPresentation {
    static let heading = "Mind map"
    static let hint = "Click a concept to see what it means, its core idea and how it connects."
    static let coreTitle = "Core"
    static let descriptionTitle = "What it is"
    static let connectionsTitle = "Connections"
    static let emptyTitle = "No mind map yet"
    static let emptyMessage = "Create one from the paper's Manage section."

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

    /// A node's tier, for its look: the paper, a main concept, or a detail.
    enum Tier { case paper, main, detail }
    static func tier(_ layout: MindMapLayout, _ id: String) -> Tier {
        id == MindMapLayout.centerId ? .paper : layout.depth[id] == 1 ? .main : .detail
    }
}
