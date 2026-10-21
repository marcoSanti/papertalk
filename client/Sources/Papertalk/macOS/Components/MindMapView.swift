// The mind map window's content: the radial graph (zoom, pinch and drag to pan) and the side
// panel describing the selected concept or connection.

#if os(macOS)
import SwiftUI

/// The paper's mind map: a radial graph of its concepts, with the selected
/// concept's description, core idea and connections in a panel beside it.
struct MindMapView: View {
    /// The map to draw; edits change it here and are handed to `onSave`.
    @State private var map: MindMap
    /// The paper's title, shown on the centre node.
    let title: String
    /// Saves an edited map; nil makes the map read-only.
    let onSave: ((MindMap) -> Void)?
    /// Opens another paper's mind map (from one of its concepts on this map); nil hides the button.
    let onOpenPaper: ((String) -> Void)?
    /// Whether the side panel shows the editing controls.
    @State private var editing = false
    /// The selected concept's text being edited, or the selected link's label (in `label`).
    private struct Draft: Equatable { var label = "", core = "", description = "" }
    @State private var draft = Draft()
    /// What the side panel shows: a concept, or an edge with both its concepts.
    private enum Selection: Equatable { case node(String), edge(String) }
    @State private var selection: Selection?
    private var selectedNode: String? { if case .node(let id) = selection { id } else { nil } }
    /// nil: fit the whole map in the window.
    @State private var zoom: Double?
    @State private var fit = 1.0
    @GestureState private var pinch = Pinch()
    /// A pinch in progress: how much, and where it started (in the viewport).
    private struct Pinch: Equatable {
        var scale = 1.0
        var location: CGPoint?
    }
    /// Where to scroll once a zoom has resized the content, to keep its anchor in place.
    @State private var pendingScroll: CGPoint?
    private static let padding = 20.0
    // Click-and-drag panning drives the scroll view's position.
    @State private var scroll = ScrollPosition()
    @State private var geometry = ScrollFrame()
    @State private var dragStart: CGPoint?

    /// What panning needs to know about the scroll view.
    private struct ScrollFrame: Equatable {
        var offset = CGPoint.zero
        var content = CGSize.zero
        var viewport = CGSize.zero
    }

    /// The map's layout and lookups, rebuilt only when the map changes: rebuilding them on every
    /// redraw (each pinch frame) made the graph lag.
    private struct Drawn {
        let layout: MindMapLayout
        let nodes: [String: MindMap.Node]
        let ids: [String]
        init(_ map: MindMap) {
            layout = MindMapLayout(map)
            nodes = Dictionary(map.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            ids = layout.positions.keys.sorted()
        }
    }
    @State private var drawn: Drawn
    private var layout: MindMapLayout { drawn.layout }
    private var nodes: [String: MindMap.Node] { drawn.nodes }
    private var ids: [String] { drawn.ids }

    /// `selected` / `selectedEdge` open with a concept or an edge already selected (previews, tests).
    init(map: MindMap, title: String, selected: String? = nil, selectedEdge: String? = nil,
         onSave: ((MindMap) -> Void)? = nil, onOpenPaper: ((String) -> Void)? = nil) {
        _map = State(initialValue: map)
        _drawn = State(initialValue: Drawn(map))
        self.title = title
        self.onSave = onSave
        self.onOpenPaper = onOpenPaper
        _selection = State(initialValue: selected.map { .node($0) } ?? selectedEdge.map { .edge($0) })
    }

    /// Apply an edit: redraw, keep the selection if it still exists, load its draft, and save.
    private func edit(_ change: (inout MindMap) -> Void) {
        change(&map)
        drawn = Drawn(map)
        if case .node(let id) = selection, map.node(id) == nil, MindMapPresentation.external(map, id) == nil { selection = nil }
        if case .edge(let id) = selection, !layout.selectableEdges.contains(where: { $0.id == id }) { selection = nil }
        loadDraft()
        onSave?(map)
    }

    /// Put the selected concept's text, or the selected link's label, in the draft.
    private func loadDraft() {
        if let id = selectedNode, let n = map.node(id) {
            draft = Draft(label: n.label, core: n.core, description: n.description)
        } else if let e = selectedEdge {
            draft = Draft(label: e.label ?? "")
        } else {
            draft = Draft()
        }
    }

    /// The selected edge, if one is.
    private var selectedEdge: MindMapLayout.Edge? {
        guard case .edge(let id) = selection else { return nil }
        return layout.selectableEdges.first { $0.id == id }
    }

    private var scale: Double { MindMapLayout.clampScale(zoom ?? fit) }
    private var viewport: (width: Double, height: Double) { (geometry.viewport.width, geometry.viewport.height) }

    /// Zoom to `newScale` keeping the map point under `anchor` (a viewport point) where it is.
    private func zoom(to newScale: Double, around anchor: CGPoint) {
        let s0 = scale, s1 = MindMapLayout.clampScale(newScale)
        guard s1 != s0 else { return }
        let o = layout.zoomedOffset(offset: .init(x: geometry.offset.x, y: geometry.offset.y),
                                    anchor: .init(x: anchor.x, y: anchor.y), from: s0, to: s1,
                                    viewport: viewport, padding: Self.padding)
        pendingScroll = CGPoint(x: o.x, y: o.y)
        zoom = s1
    }

    private var viewportCenter: CGPoint { CGPoint(x: geometry.viewport.width / 2, y: geometry.viewport.height / 2) }

    /// The pinch's preview scales around the map point under the fingers.
    private var pinchAnchor: UnitPoint {
        guard let l = pinch.location, layout.width > 0, layout.height > 0 else { return .center }
        let g = layout.mapPoint(under: .init(x: l.x, y: l.y), offset: .init(x: geometry.offset.x, y: geometry.offset.y),
                                scale: scale, viewport: viewport, padding: Self.padding)
        return UnitPoint(x: g.x / layout.width, y: g.y / layout.height)
    }

    var body: some View {
        let scale = scale
        // No toolbar: the window's title bar names the map and closes it.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        graph(layout, scale: scale)
                            // A pinch in progress only scales the drawn graph; it's laid out again once, at the end.
                            .scaleEffect(MindMapLayout.clampScale(scale * pinch.scale) / scale, anchor: pinchAnchor)
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
                    // Window coordinates: the content moves under the pointer while panning.
                    .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
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
                    .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                    .onAppear { fit = layout.fitScale(width: geo.size.width - 40, height: geo.size.height - 40) }
                    .onChange(of: geo.size) { _, size in fit = layout.fitScale(width: size.width - 40, height: size.height - 40) }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .overlay(alignment: .bottomTrailing) { zoomControls(scale) }
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = Pinch(scale: value.magnification, location: value.startLocation) }
                    .onEnded { zoom(to: scale * $0.magnification, around: $0.startLocation) })
                Divider()
                panel
                    .frame(width: 290)
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .onChange(of: selection) { _, _ in loadDraft() }
    }

    /// Zoom out, the current zoom (click to fit), zoom in.
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
            if onSave != nil {
                Divider().frame(height: 16)
                Toggle(isOn: $editing.animation(.snappy)) {
                    Label(L("Edit"), systemImage: "pencil").frame(minHeight: 24)
                }
                .toggleStyle(.button)
                .help(L("Add, change and delete concepts and connections"))
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

    /// Edges drawn on a canvas, then the nodes and edge handles over it, at `scale`.
    private func graph(_ layout: MindMapLayout, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in layout.edges {
                    guard let a = layout.positions[e.from], let b = layout.positions[e.to] else { continue }
                    var path = Path()
                    let p1 = CGPoint(x: a.x * scale, y: a.y * scale), p2 = CGPoint(x: b.x * scale, y: b.y * scale)
                    path.move(to: p1)
                    if let k = layout.control(e) {
                        path.addQuadCurve(to: p2, control: CGPoint(x: k.x * scale, y: k.y * scale))
                    } else {
                        path.addLine(to: p2)
                    }
                    let highlighted = selection == .edge(e.id)
                        || (selectedNode != nil && (e.from == selectedNode || e.to == selectedNode))
                    let color = edgeColor(e)
                    ctx.stroke(path, with: .color(color.opacity(highlighted ? 0.95 : 0.45)),
                               style: StrokeStyle(lineWidth: highlighted ? 2.5 : 1.5, lineCap: .round,
                                                  dash: e.label == nil ? [] : [5, 4]))
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)

            ForEach(ids, id: \.self) { id in
                if let p = layout.positions[id] {
                    nodeView(id, layout: layout)
                        .scaleEffect(scale)
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }

            // Above the nodes, so a handle can never hide under one.
            ForEach(layout.selectableEdges) { e in
                if let p = layout.handle(e), let detail = MindMapPresentation.edgeDetail(map, e) {
                    edgeHandle(e, detail: detail)
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }
        }
        .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
    }

    /// A concept's box, styled by tier (paper, main concept, detail); clicking selects it.
    @ViewBuilder
    private func nodeView(_ id: String, layout: MindMapLayout) -> some View {
        let tier = MindMapPresentation.tier(layout, id)
        let node = nodes[id]
        let color = node.map { Self.color($0.branch) } ?? Color.appAccent
        // Nothing selected means the paper is: its summary is the panel's default.
        let isSelected = selection == .node(id) || (selection == nil && id == MindMapLayout.centerId)
        let shape = RoundedRectangle(cornerRadius: tier == .detail ? 10 : 14, style: .continuous)
        let external = tier == .external ? MindMapPresentation.external(map, id) : nil
        Button {
            withAnimation(.snappy) { selection = node == nil && external == nil ? nil : .node(id) }
        } label: {
            Group {
                if let external {
                    VStack(spacing: 1) {
                        Text(external.label).lineLimit(1)
                        Text(external.paperTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                // The main concepts' icon sits inline, so long names keep both lines.
                } else if tier == .main, let node {
                    Text("\(Image(systemName: MindMapPresentation.branchIcon(node.branch))) \(node.label)")
                } else {
                    Text(node?.label ?? title)
                }
            }
            .font(tier == .detail || tier == .external ? .callout.weight(.medium) : .callout.weight(.bold))
            .lineLimit(tier == .paper ? 3 : 2)
            .multilineTextAlignment(.center)
            .foregroundStyle(tier == .detail || tier == .external ? Color.primary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: MindMapLayout.nodeWidth - 6, height: MindMapLayout.nodeHeight - 4)
            .background(shape.fill(tier == .external ? AnyShapeStyle(Color.secondary.opacity(0.10))
                                   : tier == .detail ? AnyShapeStyle(color.opacity(0.16)) : AnyShapeStyle(color.gradient)))
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            // Another paper's concept: a dashed grey outline, so it reads as outside this map.
            .overlay(shape.strokeBorder(Color.secondary.opacity(tier == .external && !isSelected ? 0.6 : 0),
                                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            .overlay(shape.strokeBorder(isSelected ? Color.primary : color.opacity(tier == .detail ? 0.7 : 0),
                                        lineWidth: isSelected ? 2.5 : 1))
            // Only the selected node gets a shadow: one per node was costly to draw.
            .shadow(color: .black.opacity(isSelected ? 0.25 : 0), radius: isSelected ? 8 : 0, y: 2)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(external.map { "\($0.label) — \($0.paperTitle)" } ?? node?.label ?? title)
    }

    /// Tree edges take their child's branch colour; links are grey.
    private func edgeColor(_ e: MindMapLayout.Edge) -> Color {
        if e.label != nil { return .secondary }
        return nodes[e.to].map { Self.color($0.branch) } ?? .secondary
    }

    /// Each branch's colour, also used by the side panel.
    static func color(_ b: MindMap.Branch) -> Color {
        switch b {
        case .problem: return .red
        case .method: return .blue
        case .evidence: return .green
        }
    }

    /// A link shows its label as a clickable tag; a tree edge a small dot.
    private func edgeHandle(_ e: MindMapLayout.Edge, detail: MindMapPresentation.EdgeDetail) -> some View {
        let isSelected = selection == .edge(e.id)
        let color = edgeColor(e)
        return Button {
            withAnimation(.snappy) { selection = .edge(e.id) }
        } label: {
            Group {
                if let label = e.label, !label.isEmpty {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor)
                                                              : AnyShapeStyle(Color(nsColor: .windowBackgroundColor))))
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: isSelected ? 13 : 9, height: isSelected ? 13 : 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .padding(6)   // a larger target than the dot
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(MindMapPresentation.edgeHelp(detail))
    }

    // MARK: panel

    @ViewBuilder
    private var panel: some View {
        ScrollView {
            if let id = selectedNode, let external = MindMapPresentation.external(map, id) {
                externalDetail(external)
            } else if let id = selectedNode, let node = nodes[id] {
                if editing { nodeEditor(node) } else { detail(node) }
            } else if let e = selectedEdge, let d = MindMapPresentation.edgeDetail(map, e) {
                edgeDetail(d)
                if editing, e.label != nil { linkEditor(e) }
            } else {
                paperOverview
            }
        }
        .background(.bar)
    }

    /// The default panel: the paper, its summary, then its three main concepts.
    private var paperOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(MindMapPresentation.paperHeading, systemImage: "doc.text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(MindMapPresentation.summary(map))
                .font(.callout)
                .foregroundStyle(map.summary == nil ? .secondary : .primary)
                .textSelection(.enabled)
            Divider()
            SectionLabel(title: MindMapPresentation.mainConceptsTitle, systemImage: "point.3.connected.trianglepath.dotted")
            ForEach(MindMap.Branch.allCases, id: \.self) { b in
                if let root = map.root(b) {
                    Button { withAnimation(.snappy) { selection = .node(root.id) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: MindMapPresentation.branchIcon(b))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Self.color(b).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(MindMapPresentation.branchTitle(b)).font(.caption).foregroundStyle(.secondary)
                                Text(root.label).font(.callout.weight(.semibold))
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(MindMapPresentation.hint).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Another paper's concept: which paper, how this map's concepts connect to it, and a way there.
    private func externalDetail(_ e: MindMapPresentation.ExternalNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(MindMapPresentation.externalHeading, systemImage: "arrow.up.right.square")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(e.label).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(e.paperTitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let onOpenPaper {
                Button(MindMapPresentation.openOtherMap) { onOpenPaper(e.paperId) }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            SectionLabel(title: MindMapPresentation.connectionsTitle, systemImage: "point.3.connected.trianglepath.dotted")
            ForEach(e.connections) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { withAnimation(.snappy) { selection = .node(c.id) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(c.label).font(.callout)
                            Text(c.relation).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    if editing {
                        Button(role: .destructive) {
                            edit { $0.deleteExternal(from: c.id, paperId: e.paperId, nodeId: e.nodeId) }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(L("Delete connection"))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: editing

    /// The selected concept's text, where it hangs, its links, and adding or deleting concepts.
    private func nodeEditor(_ node: MindMap.Node) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(MindMapPresentation.branchTitle(node.branch), systemImage: MindMapPresentation.branchIcon(node.branch))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.color(node.branch))
            editorField(L("Name")) { TextField(L("Name"), text: $draft.label) }
            editorField(MindMapPresentation.coreTitle) {
                TextField(MindMapPresentation.coreTitle, text: $draft.core, axis: .vertical).lineLimit(2...5)
            }
            editorField(MindMapPresentation.descriptionTitle) {
                TextField(MindMapPresentation.descriptionTitle, text: $draft.description, axis: .vertical).lineLimit(3...8)
            }
            Button(L("Save changes")) {
                edit { $0.editNode(node.id, label: draft.label, core: draft.core, description: draft.description) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft == Draft(label: node.label, core: node.core, description: node.description))
            Divider()
            Menu(L("Move under…")) {
                ForEach(map.parentOptions(for: node.id)) { p in
                    Button(p.label) { edit { $0.move(node.id, under: p.id) } }
                }
            }
            .disabled(map.parentOptions(for: node.id).isEmpty)
            Menu(L("Connect to…")) {
                ForEach(map.linkTargets(from: node.id)) { t in
                    Button(t.label) {
                        edit { $0.addLink(from: node.id, to: t.id, label: "") }
                        // Select the new connection, so it can be named straight away.
                        selection = .edge(MindMapLayout.Edge(from: node.id, to: t.id, label: "").id)
                    }
                }
            }
            .disabled(map.linkTargets(from: node.id).isEmpty)
            Button {
                var added: String?
                edit { added = $0.addNode(under: node.id, label: L("New concept")) }
                if let added { selection = .node(added) }
            } label: {
                Label(L("Add a concept under this one"), systemImage: "plus")
            }
            Button(role: .destructive) {
                edit { $0.deleteNode(node.id) }
            } label: {
                Label(L("Delete concept"), systemImage: "trash")
            }
            .disabled(!map.canDelete(node.id))
            .help(MindMapPresentation.deleteHelp(map.canDelete(node.id)))
        }
        .menuStyle(.button)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The selected link's label, and deleting it.
    private func linkEditor(_ e: MindMapLayout.Edge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            editorField(L("Relation")) { TextField(L("e.g. measured by"), text: $draft.label) }
            HStack {
                Button(L("Save changes")) { edit { $0.editLink(from: e.from, to: e.to, label: draft.label) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.label == (e.label ?? ""))
                Spacer()
                Button(role: .destructive) { edit { $0.deleteLink(from: e.from, to: e.to) } } label: {
                    Label(L("Delete connection"), systemImage: "trash")
                }
            }
        }
        .padding([.horizontal, .bottom], 16)
    }

    /// A caption above an editing control.
    private func editorField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    /// Both concepts of the selected edge, one above the other, with how they relate between them.
    private func edgeDetail(_ d: MindMapPresentation.EdgeDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(MindMapPresentation.connectionHeading, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            conceptCard(d.top)
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text(d.relation).italic()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            conceptCard(d.bottom)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One concept in the edge panel; clicking it opens that concept.
    private func conceptCard(_ node: MindMap.Node) -> some View {
        let color = Self.color(node.branch)
        return Button { withAnimation(.snappy) { selection = .node(node.id) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(MindMapPresentation.branchTitle(node.branch), systemImage: MindMapPresentation.branchIcon(node.branch))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text(node.label).font(.headline)
                if !node.core.isEmpty {
                    Text(node.core).font(.callout.weight(.medium))
                }
                if !node.description.isEmpty {
                    Text(node.description).font(.callout).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The side panel for a selected concept: branch, name, core, description and connections.
    private func detail(_ node: MindMap.Node) -> some View {
        let color = Self.color(node.branch)
        return VStack(alignment: .leading, spacing: 14) {
            Label(MindMapPresentation.branchTitle(node.branch), systemImage: MindMapPresentation.branchIcon(node.branch))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(node.label).font(.title3.weight(.semibold)).textSelection(.enabled)

            if !node.core.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(title: MindMapPresentation.coreTitle, systemImage: "star")
                    Text(node.core).font(.callout.weight(.medium)).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !node.description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(title: MindMapPresentation.descriptionTitle, systemImage: "text.alignleft")
                    Text(node.description).font(.callout).textSelection(.enabled)
                }
            }
            let connections = MindMapPresentation.connections(map, of: node.id)
            if !connections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: MindMapPresentation.connectionsTitle, systemImage: "point.3.connected.trianglepath.dotted")
                    ForEach(connections) { c in
                        Button { withAnimation(.snappy) { selection = .node(c.id) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(c.relation).font(.caption).foregroundStyle(.secondary)
                                Text(c.label).font(.callout)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
