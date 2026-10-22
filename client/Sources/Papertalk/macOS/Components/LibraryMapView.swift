// The library map window's content: the library's papers on a ring, coloured by cluster, lines
// between papers whose mind maps connect (grey ones to papers outside the library), dragging to
// pan or move papers, zoom (buttons and pinch) as in the mind map, and a side panel with the selected paper's or line's connections.

#if os(macOS)
import SwiftUI

/// A library's papers as a graph: thicker lines for more connections, each with its count as a
/// clickable badge; the panel lists what connects and opens a paper's own mind map.
struct LibraryMapView: View {
    let map: LibraryMap
    /// Opens a paper's mind map window.
    let onOpenPaper: (String) -> Void
    /// What the side panel shows: a paper, or a line between two.
    private enum Selection: Equatable { case paper(String), edge(String) }
    @State private var selection: Selection?
    /// Papers the user has dragged, and where the one being dragged started.
    @State private var moved: [String: MindMapLayout.Point] = [:]
    @State private var moveStart: MindMapLayout.Point?
    /// nil: fit the whole map in the window.
    @State private var zoom: Double?
    @GestureState private var pinch = Pinch()
    /// A pinch in progress: how much, and where it started (in the viewport).
    private struct Pinch: Equatable {
        var scale = 1.0
        var location: CGPoint?
    }
    /// Where to scroll once a zoom has resized the content, to keep its anchor in place.
    @State private var pendingScroll: CGPoint?
    private static let padding = 20.0
    // Click-and-drag panning drives the scroll view's position, as in the mind map.
    @State private var scroll = ScrollPosition()
    @State private var geometry = ScrollFrame()
    @State private var dragStart: CGPoint?

    /// What panning needs to know about the scroll view.
    private struct ScrollFrame: Equatable {
        var offset = CGPoint.zero
        var content = CGSize.zero
        var viewport = CGSize.zero
    }

    init(map: LibraryMap, onOpenPaper: @escaping (String) -> Void) {
        self.map = map
        self.onOpenPaper = onOpenPaper
    }

    /// Each cluster's colour, in turn; papers in no cluster are grey.
    static func color(_ cluster: Int?) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .brown, .mint, .cyan]
        return cluster.map { palette[$0 % palette.count] } ?? .gray
    }

    /// Laid out for the window's size (not the zoom), so a bigger window spreads the papers out.
    private var layout: LibraryMapLayout {
        LibraryMapLayout(map, minWidth: geometry.viewport.width - 2 * Self.padding,
                         minHeight: geometry.viewport.height - 2 * Self.padding).arranged(moved)
    }

    private var viewport: (width: Double, height: Double) { (geometry.viewport.width, geometry.viewport.height) }
    private var viewportCenter: CGPoint { CGPoint(x: geometry.viewport.width / 2, y: geometry.viewport.height / 2) }

    private func scale(_ layout: LibraryMapLayout) -> Double {
        MindMapLayout.clampScale(zoom ?? layout.fitScale(width: viewport.width - 2 * Self.padding,
                                                         height: viewport.height - 2 * Self.padding))
    }

    /// Zoom to `newScale` keeping the map point under `anchor` (a viewport point) where it is.
    private func zoom(to newScale: Double, around anchor: CGPoint) {
        let layout = layout
        let s0 = scale(layout), s1 = MindMapLayout.clampScale(newScale)
        guard s1 != s0 else { return }
        let o = layout.zoomedOffset(offset: .init(x: geometry.offset.x, y: geometry.offset.y),
                                    anchor: .init(x: anchor.x, y: anchor.y), from: s0, to: s1,
                                    viewport: viewport, padding: Self.padding)
        pendingScroll = CGPoint(x: o.x, y: o.y)
        zoom = s1
    }

    /// The pinch's preview scales around the map point under the fingers.
    private func pinchAnchor(_ layout: LibraryMapLayout, scale: Double) -> UnitPoint {
        guard let l = pinch.location, layout.width > 0, layout.height > 0 else { return .center }
        let g = layout.mapPoint(under: .init(x: l.x, y: l.y), offset: .init(x: geometry.offset.x, y: geometry.offset.y),
                                scale: scale, viewport: viewport, padding: Self.padding)
        return UnitPoint(x: g.x / layout.width, y: g.y / layout.height)
    }

    var body: some View {
        let layout = layout
        let scale = scale(layout)
        HStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    graph(layout, scale: scale)
                        // A pinch in progress only scales the drawn graph; it's laid out again once, at the end.
                        .scaleEffect(MindMapLayout.clampScale(scale * pinch.scale) / scale,
                                     anchor: pinchAnchor(layout, scale: scale))
                        .padding(Self.padding)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: ScrollFrame.self) {
                    ScrollFrame(offset: $0.contentOffset, content: $0.contentSize, viewport: $0.containerSize)
                } action: { old, frame in
                    geometry = frame
                    // The zoomed content has its new size now: scroll so the anchor stays put.
                    if let target = pendingScroll, frame.content != old.content {
                        pendingScroll = nil
                        scroll.scrollTo(point: target)
                    }
                }
                .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(alignment: .bottomTrailing) { zoomControls(scale) }
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = Pinch(scale: value.magnification, location: value.startLocation) }
                .onEnded { zoom(to: scale * $0.magnification, around: $0.startLocation) })
            Divider()
            ScrollView { panel }
                .frame(width: 290)
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    /// Zoom out, the current zoom (click to fit), zoom in, and undo the dragging.
    private func zoomControls(_ scale: Double) -> some View {
        HStack(spacing: 2) {
            Button { zoom(to: scale / 1.25, around: viewportCenter) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 26, height: 24)
            }
            .help(L("Zoom out"))
            Button { zoom = nil } label: {
                Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(minWidth: 44, minHeight: 24)
            }
            .help(L("Fit the whole map"))
            Button { zoom(to: scale * 1.25, around: viewportCenter) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 26, height: 24)
            }
            .help(L("Zoom in"))
            if !moved.isEmpty {
                Button { withAnimation(.snappy) { moved = [:] } } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 24)
                }
                .help(LibraryMapPresentation.resetArrangement)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .padding(12)
    }

    // MARK: graph

    private var selectedPaper: String? { if case .paper(let id) = selection { id } else { nil } }

    private func highlighted(_ e: LibraryMap.Edge) -> Bool {
        selection == .edge(e.id) || e.a == selectedPaper || e.b == selectedPaper
    }

    /// Drags paper `id` around the map.
    private func moveGesture(_ id: String, layout: LibraryMapLayout, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { drag in
                guard let start = moveStart ?? layout.positions[id] else { return }
                moveStart = start
                moved[id] = layout.dragged(from: start, dx: drag.translation.width, dy: drag.translation.height, scale: scale)
            }
            .onEnded { _ in moveStart = nil }
    }

    /// Lines on a canvas, then the papers and the lines' count badges over it, at `scale`.
    private func graph(_ layout: LibraryMapLayout, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in map.edges {
                    guard let a = layout.positions[e.a], let b = layout.positions[e.b] else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: a.x * scale, y: a.y * scale))
                    path.addLine(to: CGPoint(x: b.x * scale, y: b.y * scale))
                    let on = highlighted(e)
                    let color = map.isOutside(e) ? Color.secondary : Self.color(map.cluster(of: e))
                    ctx.stroke(path, with: .color(color.opacity(on ? 0.95 : 0.4)),
                               style: StrokeStyle(lineWidth: (1.5 + 0.75 * Double(min(e.links.count, 6))) * (on ? 1.4 : 1),
                                                  lineCap: .round))
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)

            ForEach(map.nodes) { node in
                if let p = layout.positions[node.id] {
                    paperView(node)
                        .scaleEffect(scale)
                        // High priority: a Button holds the mouse until it's released.
                        .highPriorityGesture(moveGesture(node.id, layout: layout, scale: scale))
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }

            ForEach(map.edges) { e in
                if let a = layout.positions[e.a], let b = layout.positions[e.b] {
                    badge(e)
                        .position(x: (a.x + b.x) / 2 * scale, y: (a.y + b.y) / 2 * scale)
                }
            }
        }
        .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
        // On the graph, so a drag that starts on a paper moves it instead.
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? geometry.offset
                dragStart = start
                let p = MindMapLayout.panned(from: .init(x: start.x, y: start.y),
                                             dx: drag.translation.width, dy: drag.translation.height,
                                             content: (geometry.content.width, geometry.content.height),
                                             viewport: (geometry.viewport.width, geometry.viewport.height))
                scroll.scrollTo(point: CGPoint(x: p.x, y: p.y))
            }
            .onEnded { _ in dragStart = nil })
    }

    /// A paper's box: filled in its cluster's colour when it has a mind map, faint when it
    /// doesn't, grey and dashed when it's outside the library.
    private func paperView(_ node: LibraryMap.Node) -> some View {
        let selected = selection == .paper(node.id)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let filled = node.hasMindMap && !node.isOutside
        let color = Self.color(node.cluster)
        return Button { withAnimation(.snappy) { selection = .paper(node.id) } } label: {
            Text(node.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(filled ? Color.white : node.isOutside ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: LibraryMapLayout.nodeWidth - 6, height: LibraryMapLayout.nodeHeight - 4)
                .background(shape.fill(filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.secondary.opacity(0.12))))
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(Color.secondary.opacity(node.isOutside && !selected ? 0.6 : 0),
                                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .overlay(shape.strokeBorder(Color.primary.opacity(selected ? 1 : 0), lineWidth: 2.5))
                .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: selected ? 8 : 0, y: 2)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(node.title)
    }

    /// A line's connection count; clicking it selects the line.
    private func badge(_ e: LibraryMap.Edge) -> some View {
        let on = selection == .edge(e.id)
        let color = map.isOutside(e) ? Color.secondary : Self.color(map.cluster(of: e))
        return Button { withAnimation(.snappy) { selection = .edge(e.id) } } label: {
            Text("\(e.links.count)")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 4)
                .background(Capsule().fill(on ? AnyShapeStyle(color) : AnyShapeStyle(.regularMaterial)))
                .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(LibraryMapPresentation.linkCount(e.links.count))
    }

    // MARK: panel

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch selection {
            case .paper(let id):
                if let node = map.node(id) { paperDetail(node) }
            case .edge(let id):
                if let e = map.edges.first(where: { $0.id == id }) { edgeDetail(e) }
            case nil:
                Text(LibraryMapPresentation.overview(map)).font(.title3.weight(.semibold))
                if let note = LibraryMapPresentation.emptyNote(map) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Text(LibraryMapPresentation.hint).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A paper: its title, its mind map, and the papers it connects to.
    @ViewBuilder
    private func paperDetail(_ node: LibraryMap.Node) -> some View {
        if node.isOutside {
            Label(LibraryMapPresentation.outsideHeading, systemImage: "arrow.up.right.square")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        Text(node.title).font(.title3.weight(.semibold)).textSelection(.enabled)
        if node.hasMindMap {
            Button(LibraryMapPresentation.openMindMap) { onOpenPaper(node.id) }
                .buttonStyle(.borderedProminent)
        } else {
            Text(LibraryMapPresentation.noMindMap).font(.callout).foregroundStyle(.secondary)
        }
        Divider()
        SectionLabel(title: LibraryMapPresentation.connectedPapers, systemImage: "point.3.connected.trianglepath.dotted")
        let edges = map.edges(of: node.id)
        if edges.isEmpty {
            Text(LibraryMapPresentation.noConnections).font(.callout).foregroundStyle(.secondary)
        }
        ForEach(edges) { e in
            Button { withAnimation(.snappy) { selection = .edge(e.id) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(map.other(e, from: node.id)?.title ?? "").font(.callout)
                        Text(LibraryMapPresentation.linkCount(e.links.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A line: the two papers (click to select one) and each concept connection between them.
    @ViewBuilder
    private func edgeDetail(_ e: LibraryMap.Edge) -> some View {
        ForEach([e.a, e.b], id: \.self) { id in
            if let node = map.node(id) {
                Button { withAnimation(.snappy) { selection = .paper(id) } } label: {
                    Label(node.title, systemImage: "doc.text").font(.callout.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        Divider()
        SectionLabel(title: LibraryMapPresentation.connectionsTitle, systemImage: "point.3.connected.trianglepath.dotted")
        ForEach(e.links) { l in
            VStack(alignment: .leading, spacing: 2) {
                Text(l.fromLabel).font(.callout)
                Text(l.label).font(.caption).foregroundStyle(Color.appAccent)
                Text(l.toLabel).font(.callout)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
#endif
