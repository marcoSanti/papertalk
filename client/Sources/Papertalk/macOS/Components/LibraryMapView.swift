// The library map window's content: the library's papers on a ring, coloured by cluster, lines
// between papers whose mind maps connect (grey ones to papers outside the library), dragging to
// pan or move papers, and a side panel with the selected paper's or line's connections.

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

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                // Laid out for the window's size, so a bigger window spreads the papers out.
                let layout = LibraryMapLayout(map, minWidth: geo.size.width - 40, minHeight: geo.size.height - 40).arranged(moved)
                let scale = layout.fitScale(width: geo.size.width - 40, height: geo.size.height - 40)
                ScrollView([.horizontal, .vertical]) {
                    graph(layout, scale: scale)
                        .padding(20)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: ScrollFrame.self) {
                    ScrollFrame(offset: $0.contentOffset, content: $0.contentSize, viewport: $0.containerSize)
                } action: { _, frame in geometry = frame }
                .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(alignment: .bottomTrailing) {
                if !moved.isEmpty {
                    Button { withAnimation(.snappy) { moved = [:] } } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
                    .padding(12)
                    .help(LibraryMapPresentation.resetArrangement)
                }
            }
            Divider()
            ScrollView { panel }
                .frame(width: 290)
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
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
