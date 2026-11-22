// The zoomable canvas under the mind map and the library map: scroll, click-and-drag to pan,
// pinch or buttons to zoom around a point.

#if os(macOS)
import SwiftUI

/// When "fit the whole map" is worked out again.
enum MapFit {
    /// When the window resizes: an edit doesn't move the map under the reader.
    case onResize
    /// Always: the layout follows the window.
    case continuous
}

/// Space around a map in its scroll view.
let mapPadding = 20.0

/// A map of any `ZoomableLayout`. The caller draws the graph at the given scale, sized to it, and
/// adds its own buttons after the zoom ones.
struct ZoomableMap<Map: ZoomableLayout, Graph: View, Controls: View>: View {
    /// The map laid out for a viewport's size.
    let layout: (CGSize) -> Map
    let fitting: MapFit
    /// A click on the empty canvas.
    let onBackgroundTap: () -> Void
    /// The graph, given the layout, the scale and the window area it's shown in.
    @ViewBuilder let graph: (Map, Double, CGSize) -> Graph
    @ViewBuilder let controls: () -> Controls

    /// nil: fit the whole map in the window.
    @State private var zoom: Double?
    @State private var fit = 1.0
    @GestureState private var pinch = Pinch()
    /// Where to scroll once a zoom has resized the content, to keep its anchor in place.
    @State private var pendingScroll: CGPoint?
    // Click-and-drag panning drives the scroll view's position.
    @State private var scroll = ScrollPosition()
    @State private var geometry = ScrollFrame()
    @State private var dragStart: CGPoint?

    private var viewport: (width: Double, height: Double) { (geometry.viewport.width, geometry.viewport.height) }
    private var viewportCenter: CGPoint { CGPoint(x: geometry.viewport.width / 2, y: geometry.viewport.height / 2) }

    private func fitted(_ map: Map, in size: CGSize) -> Double {
        map.fitScale(width: size.width - 2 * mapPadding, height: size.height - 2 * mapPadding)
    }

    private func scale(_ map: Map) -> Double {
        MindMapLayout.clampScale(zoom ?? (fitting == .continuous ? fitted(map, in: geometry.viewport) : fit))
    }

    /// Zoom to `newScale` keeping the map point under `anchor` (a viewport point) where it is.
    private func zoom(to newScale: Double, around anchor: CGPoint) {
        let map = layout(geometry.viewport)
        let s0 = scale(map), s1 = MindMapLayout.clampScale(newScale)
        guard s1 != s0 else { return }
        let o = map.zoomedOffset(offset: .init(x: geometry.offset.x, y: geometry.offset.y),
                                 anchor: .init(x: anchor.x, y: anchor.y), from: s0, to: s1,
                                 viewport: viewport, padding: mapPadding)
        pendingScroll = CGPoint(x: o.x, y: o.y)
        zoom = s1
    }

    /// The pinch's preview scales around the map point under the fingers.
    private func pinchAnchor(_ map: Map, scale: Double) -> UnitPoint {
        guard let l = pinch.location, map.width > 0, map.height > 0 else { return .center }
        let g = map.mapPoint(under: .init(x: l.x, y: l.y), offset: .init(x: geometry.offset.x, y: geometry.offset.y),
                             scale: scale, viewport: viewport, padding: mapPadding)
        return UnitPoint(x: g.x / map.width, y: g.y / map.height)
    }

    var body: some View {
        let map = layout(geometry.viewport)
        let scale = scale(map)
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                graph(map, scale, geo.size)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onBackgroundTap)
                    // On the graph, not the scroll view: a drag that starts on a node or a handle moves
                    // that instead. Window coordinates: the content moves under the pointer while panning.
                    .gesture(pan)
                    // A pinch in progress only scales the drawn graph; it's laid out again once, at the end.
                    .scaleEffect(MindMapLayout.clampScale(scale * pinch.scale) / scale, anchor: pinchAnchor(map, scale: scale))
                    .padding(mapPadding)
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
            .onAppear { fit = fitted(map, in: geo.size) }
            .onChange(of: geo.size) { _, size in fit = fitted(map, in: size) }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottomTrailing) { zoomControls(scale) }
        .gesture(MagnifyGesture()
            .updating($pinch) { value, state, _ in state = Pinch(scale: value.magnification, location: value.startLocation) }
            .onEnded { zoom(to: scale * $0.magnification, around: $0.startLocation) })
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? geometry.offset
                dragStart = start
                let p = MindMapLayout.panned(from: .init(x: start.x, y: start.y),
                                             dx: drag.translation.width, dy: drag.translation.height,
                                             content: (geometry.content.width, geometry.content.height),
                                             viewport: viewport)
                scroll.scrollTo(point: CGPoint(x: p.x, y: p.y))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Zoom out, the current zoom (click to fit), zoom in, then the map's own buttons.
    private func zoomControls(_ scale: Double) -> some View {
        HStack(spacing: 2) {
            Button { zoom(to: scale / 1.25, around: viewportCenter) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 26, height: 24)
            }
            .help(L("Zoom out"))
            Button { zoom = nil } label: {
                Text(MindMapPresentation.zoomLabel(scale)).monospacedDigit().frame(minWidth: 44, minHeight: 24)
            }
            .help(L("Fit the whole map"))
            Button { zoom(to: scale * 1.25, around: viewportCenter) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 26, height: 24)
            }
            .help(L("Zoom in"))
            controls()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .padding(12)
    }
}

/// A pinch in progress: how much, and where it started (in the viewport).
private struct Pinch: Equatable {
    var scale = 1.0
    var location: CGPoint?
}

/// What panning needs to know about the scroll view.
private struct ScrollFrame: Equatable {
    var offset = CGPoint.zero
    var content = CGSize.zero
    var viewport = CGSize.zero
}

/// The button that undoes the user's dragging.
struct ResetArrangementButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 24)
        }
        .help(help)
    }
}
#endif
