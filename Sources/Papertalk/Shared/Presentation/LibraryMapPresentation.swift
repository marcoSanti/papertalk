// The library map's layout (force-directed, dragged to rearrange) and wording.

import Foundation

/// Where each paper sits: seeded on rings (the library's, outside papers around it), then
/// relaxed by `ForceLayout` so connected papers sit close and boxes don't touch (a single
/// paper in the middle). Papers the user dragged go where they were dropped (`arranged`).
struct LibraryMapLayout: Equatable, ZoomableLayout {
    /// Paper id → centre of its box, in points from the top-left.
    private(set) var positions: [String: MindMapLayout.Point] = [:]

    /// This layout with dragged papers (id → where dropped) moved, kept on the canvas if the
    /// window has shrunk since; unknown ids are ignored.
    func arranged(_ moved: [String: MindMapLayout.Point]) -> LibraryMapLayout {
        var l = self
        for (id, p) in moved where l.positions[id] != nil { l.positions[id] = dragged(from: p, dx: 0, dy: 0, scale: 1) }
        return l
    }

    private(set) var width = 0.0, height = 0.0
    /// Paper box the layout leaves room for.
    static let nodeWidth = 190.0, nodeHeight = 70.0
    private static let minRadius = 200.0, ringGap = 240.0, margin = 40.0

    /// The layout on a canvas of at least `minWidth` × `minHeight` (the window's graph area):
    /// papers start on rings, then forces pull connected papers together and push the rest
    /// apart; the result stretches, wider or taller, to fill the room the papers don't need.
    init(_ map: LibraryMap, minWidth: Double = 0, minHeight: Double = 0) {
        func radius(_ n: Int) -> Double { Double(n) * (Self.nodeWidth + 30) / (2 * .pi) }
        let inner = map.members, outer = map.nodes.filter(\.isOutside)
        let r = inner.count <= 1 ? 0 : max(Self.minRadius, radius(inner.count))
        let r2 = outer.isEmpty ? r : max(r + Self.ringGap, radius(outer.count))
        // Seed: start at the top and go clockwise; the outer ring starts half a step on.
        var seed: [String: MindMapLayout.Point] = [:]
        for (ring, radius, shift) in [(inner, r, 0.0), (outer, r2, 0.5)] {
            for (i, node) in ring.enumerated() {
                let a = -Double.pi / 2 + 2 * .pi * (Double(i) + shift) / Double(max(ring.count, 1))
                seed[node.id] = .init(x: radius * cos(a), y: radius * sin(a))
            }
        }
        let raw = ForceLayout.relax(seed, edges: map.edges.map { ($0.a, $0.b) },
                                    box: (Self.nodeWidth, Self.nodeHeight), gap: (30, 30))
        let xs = raw.values.map(\.x), ys = raw.values.map(\.y)
        let spanX = (xs.max() ?? 0) - (xs.min() ?? 0), spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
        width = max(minWidth, spanX + Self.nodeWidth + 2 * Self.margin)
        height = max(minHeight, spanY + Self.nodeHeight + 2 * Self.margin)
        // How far the layout can stretch each way; stretching only moves papers apart.
        let sx = spanX > 0 ? (width - Self.nodeWidth - 2 * Self.margin) / spanX : 1
        let sy = spanY > 0 ? (height - Self.nodeHeight - 2 * Self.margin) / spanY : 1
        let midX = ((xs.max() ?? 0) + (xs.min() ?? 0)) / 2, midY = ((ys.max() ?? 0) + (ys.min() ?? 0)) / 2
        positions = raw.mapValues { .init(x: width / 2 + sx * ($0.x - midX), y: height / 2 + sy * ($0.y - midY)) }
    }
}

/// The library map window's wording.
enum LibraryMapPresentation {
    /// What the side panel shows: a paper, or a line between two.
    enum Selection: Equatable { case paper(String), edge(String) }
    /// Whether a line stands out: it's selected, or it touches the selected paper.
    static func isHighlighted(_ e: LibraryMap.Edge, _ s: Selection?) -> Bool {
        switch s {
        case .edge(let id): id == e.id
        case .paper(let id): e.a == id || e.b == id
        case nil: false
        }
    }
    /// The number on a line's badge.
    static func badgeLabel(_ e: LibraryMap.Edge) -> String { "\(e.links.count)" }
    /// The window's title.
    static func title(_ library: String) -> String { L("Paper connections — {0}", library) }
    /// The sidebar menu item and toolbar button that open it.
    static var open: String { L("Show Paper Connections") }
    static var openHelp: String { L("See how this library's papers connect through their mind maps") }
    /// The toolbar button works only inside a library, not in All Papers or a tag.
    static func canOpen(library: String?) -> Bool { library != nil }
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
