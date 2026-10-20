#if os(macOS)
import SwiftUI

/// The paper's mind map: a radial graph of its concepts, with the selected
/// concept's description, core idea and connections in a panel beside it.
struct MindMapView: View {
    let map: MindMap
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    init(map: MindMap, title: String, selected: String? = nil) {
        self.map = map
        self.title = title
        _selected = State(initialValue: selected)
    }
    /// nil: fit the whole map in the window.
    @State private var zoom: Double?
    @State private var fit = 1.0
    @GestureState private var pinch = 1.0

    private var layout: MindMapLayout { MindMapLayout(map) }

    var body: some View {
        let layout = layout
        let scale = MindMapLayout.clampScale((zoom ?? fit) * pinch)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.appAccent.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(MindMapPresentation.heading).font(.headline)
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                HStack(spacing: 4) {
                    Button { zoom = MindMapLayout.clampScale(scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom = nil } label: { Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(minWidth: 40) }
                        .help("Fit the whole map")
                    Button { zoom = MindMapLayout.clampScale(scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                }
                .buttonStyle(.borderless)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        graph(layout, scale: scale)
                            .padding(20)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .onAppear { fit = layout.fitScale(width: geo.size.width - 40, height: geo.size.height - 40) }
                    .onChange(of: geo.size) { _, size in fit = layout.fitScale(width: size.width - 40, height: size.height - 40) }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { zoom = MindMapLayout.clampScale((zoom ?? fit) * $0.magnification) })
                Divider()
                panel
                    .frame(width: 290)
            }
        }
        .frame(width: 1080, height: 720)
    }

    // MARK: graph

    private func graph(_ layout: MindMapLayout, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in layout.edges {
                    guard let a = layout.positions[e.from], let b = layout.positions[e.to] else { continue }
                    var path = Path()
                    let p1 = CGPoint(x: a.x * scale, y: a.y * scale), p2 = CGPoint(x: b.x * scale, y: b.y * scale)
                    path.move(to: p1)
                    if e.label == nil {
                        path.addLine(to: p2)
                    } else {
                        // Links across branches bow towards the centre, so they don't run over tree edges.
                        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                        let c = layout.positions[MindMapLayout.centerId].map { CGPoint(x: $0.x * scale, y: $0.y * scale) } ?? mid
                        path.addQuadCurve(to: p2, control: CGPoint(x: (mid.x + c.x) / 2, y: (mid.y + c.y) / 2))
                    }
                    let highlighted = selected != nil && (e.from == selected || e.to == selected)
                    let color = edgeColor(e)
                    ctx.stroke(path, with: .color(color.opacity(highlighted ? 0.95 : 0.45)),
                               style: StrokeStyle(lineWidth: highlighted ? 2.5 : 1.5, lineCap: .round,
                                                  dash: e.label == nil ? [] : [5, 4]))
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)

            ForEach(Array(layout.positions.keys.sorted()), id: \.self) { id in
                if let p = layout.positions[id] {
                    nodeView(id, layout: layout)
                        .scaleEffect(scale)
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }
        }
        .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { selected = nil }
    }

    @ViewBuilder
    private func nodeView(_ id: String, layout: MindMapLayout) -> some View {
        let tier = MindMapPresentation.tier(layout, id)
        let node = map.node(id)
        let color = node.map { Self.color($0.branch) } ?? Color.appAccent
        let isSelected = selected == id
        let shape = RoundedRectangle(cornerRadius: tier == .detail ? 10 : 14, style: .continuous)
        Button {
            withAnimation(.snappy) { selected = node == nil ? nil : id }
        } label: {
            VStack(spacing: 2) {
                if tier == .main, let node {
                    Image(systemName: MindMapPresentation.branchIcon(node.branch)).font(.caption.weight(.bold))
                }
                Text(node?.label ?? title)
                    .font(tier == .detail ? .callout.weight(.medium) : .callout.weight(.bold))
                    .lineLimit(tier == .paper ? 3 : 2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tier == .detail ? Color.primary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: MindMapLayout.nodeWidth - 6, height: MindMapLayout.nodeHeight - 4)
            .background(shape.fill(tier == .detail ? AnyShapeStyle(color.opacity(0.16)) : AnyShapeStyle(color.gradient)))
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(shape.strokeBorder(isSelected ? Color.primary : color.opacity(tier == .detail ? 0.7 : 0),
                                        lineWidth: isSelected ? 2.5 : 1))
            .shadow(color: .black.opacity(isSelected ? 0.25 : 0.08), radius: isSelected ? 8 : 3, y: 2)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(node?.label ?? title)
    }

    private func edgeColor(_ e: MindMapLayout.Edge) -> Color {
        if e.label != nil { return .secondary }
        return map.node(e.to).map { Self.color($0.branch) } ?? .secondary
    }

    static func color(_ b: MindMap.Branch) -> Color {
        switch b {
        case .problem: return .red
        case .method: return .blue
        case .evidence: return .green
        }
    }

    // MARK: panel

    @ViewBuilder
    private var panel: some View {
        ScrollView {
            if let id = selected, let node = map.node(id) {
                detail(node)
            } else {
                overview
            }
        }
        .background(.bar)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(MindMapPresentation.hint).font(.callout).foregroundStyle(.secondary)
            ForEach(MindMap.Branch.allCases, id: \.self) { b in
                if let root = map.root(b) {
                    Button { withAnimation(.snappy) { selected = root.id } } label: {
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
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                        Button { withAnimation(.snappy) { selected = c.id } } label: {
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
