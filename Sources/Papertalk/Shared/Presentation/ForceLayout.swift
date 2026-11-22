// Force-directed clean-up for the graph views: nodes push each other apart, lines pull their
// ends together, then any boxes still touching are separated. Pure and deterministic.

import Foundation

/// Relaxes a seeded layout (Fruchterman–Reingold): near pairs repel, every edge attracts, a
/// weak pull keeps the graph together, and an optional pull back to the seed keeps its shape.
enum ForceLayout {
    typealias Point = MindMapLayout.Point

    /// `seed` relaxed for boxes of `box` size kept `gap` apart. `pinned` nodes don't move;
    /// `anchor` (0 = none) pulls each node back towards its seed, `gravity` towards the middle.
    static func relax(_ seed: [String: Point], edges: [(String, String)], box: (w: Double, h: Double),
                      gap: (x: Double, y: Double), pinned: Set<String> = [], anchor: Double = 0, gravity: Double = 0.1,
                      iterations: Int = 300) -> [String: Point] {
        let ids = seed.keys.sorted()
        guard ids.count > 1 else { return seed }
        // Work in units of one box plus its gap, so wide boxes count as round.
        let ux = box.w + gap.x, uy = box.h + gap.y
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let start = ids.map { Point(x: seed[$0]!.x / ux, y: seed[$0]!.y / uy) }
        let fixed = ids.map { pinned.contains($0) }
        let links = edges.compactMap { e -> (Int, Int)? in
            guard let a = index[e.0], let b = index[e.1], a != b else { return nil }
            return (a, b)
        }
        let k = 1.6
        var p = start
        for step in 0..<iterations {
            var d = [Point](repeating: Point(x: 0, y: 0), count: p.count)
            for i in p.indices {
                for j in p.indices where j > i {
                    var dx = p[i].x - p[j].x, dy = p[i].y - p[j].y
                    if hypot(dx, dy) < 1e-3 { dx = cos(Double(i + j)); dy = sin(Double(i + j)) }  // coincident: split apart
                    // Only near neighbours repel, so unconnected nodes don't drift far apart.
                    guard hypot(dx, dy) < 2 * k else { continue }
                    let dist = max(hypot(dx, dy), 0.05), f = k * k / (dist * dist)
                    d[i].x += dx * f; d[i].y += dy * f
                    d[j].x -= dx * f; d[j].y -= dy * f
                }
            }
            for (a, b) in links {
                let dx = p[a].x - p[b].x, dy = p[a].y - p[b].y, f = hypot(dx, dy) / k
                d[a].x -= dx * f; d[a].y -= dy * f
                d[b].x += dx * f; d[b].y += dy * f
            }
            let cx = p.map(\.x).reduce(0, +) / Double(p.count), cy = p.map(\.y).reduce(0, +) / Double(p.count)
            // The step shrinks as the layout cools, so it settles instead of oscillating.
            let t = 0.5 * (1 - Double(step) / Double(iterations)) + 0.01
            for i in p.indices where !fixed[i] {
                let fx = d[i].x - gravity * (p[i].x - cx) + anchor * (start[i].x - p[i].x)
                let fy = d[i].y - gravity * (p[i].y - cy) + anchor * (start[i].y - p[i].y)
                let len = hypot(fx, fy)
                guard len > 0 else { continue }
                p[i].x += fx / len * min(len, t); p[i].y += fy / len * min(len, t)
            }
        }
        var out = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Point(x: p[$0].x * ux, y: p[$0].y * uy)) })
        separate(&out, ids: ids, w: ux, h: uy, pinned: pinned)
        return out
    }

    /// Pushes apart boxes closer than `w` × `h`, along the axis that needs the smaller move.
    private static func separate(_ p: inout [String: Point], ids: [String], w: Double, h: Double, pinned: Set<String>) {
        for _ in 0..<200 {
            var moved = false
            for (i, a) in ids.enumerated() {
                for b in ids[(i + 1)...] {
                    let dx = p[b]!.x - p[a]!.x, dy = p[b]!.y - p[a]!.y
                    let ox = w - abs(dx), oy = h - abs(dy)
                    guard ox > 1e-6, oy > 1e-6 else { continue }
                    moved = true
                    let sa = pinned.contains(a) ? 0.0 : pinned.contains(b) ? 1 : 0.5, sb = pinned.contains(b) ? 0.0 : 1 - sa
                    if ox / w < oy / h {
                        let s = dx < 0 ? -1.0 : 1
                        p[a]!.x -= s * ox * sa; p[b]!.x += s * ox * sb
                    } else {
                        let s = dy < 0 ? -1.0 : 1
                        p[a]!.y -= s * oy * sa; p[b]!.y += s * oy * sb
                    }
                }
            }
            if !moved { return }
        }
    }
}
