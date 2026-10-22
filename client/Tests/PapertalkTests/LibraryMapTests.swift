// Tests of the library map: building the paper graph from mind map connections, its clusters,
// its ring layout (outside papers on a ring of their own) and dragging, its wording, and the
// store reading a library's maps from disk.

import XCTest
@testable import Papertalk

final class LibraryMapTests: PapertalkTestCase {
    private typealias F = ConnectionFixtures

    private static func link(_ from: String, to paper: String, _ node: String, _ label: String) -> MindMap.ExternalLink {
        MindMap.ExternalLink(from: from, paperId: paper, paperTitle: paper.uppercased(), nodeId: node, nodeLabel: node, label: label)
    }

    private static func paper(_ id: String, _ title: String) -> Paper { Fixtures.paper(id: id, title: title) }

    func testMirroredConnectionsCountOnceAndOutsidePapersAreLeftOut() {
        var a = F.new, b = F.related
        a.external = [Self.link("attn", to: "b", "heads", "same idea"), Self.link("bench", to: "b", "heads", "measures"),
                      Self.link("attn", to: "outside", "x", "far away")]
        // b's mirror of the first connection, plus a stale repeat of it.
        b.external = [Self.link("heads", to: "a", "attn", "same idea"), Self.link("heads", to: "a", "attn", "same idea")]
        let map = LibraryMap(papers: [Self.paper("b", "Beta"), Self.paper("a", "Alpha"), Self.paper("c", "Gamma")],
                             maps: ["a": a, "b": b])

        XCTAssertEqual(map.nodes.map(\.title), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(map.nodes.map(\.hasMindMap), [true, true, false])
        XCTAssertEqual(map.edges.count, 1)
        let e = try! XCTUnwrap(map.edges.first)
        XCTAssertEqual([e.a, e.b], ["a", "b"])
        XCTAssertEqual(e.links, [LibraryMap.Link(fromLabel: "Sparse attention", toLabel: "heads", label: "same idea"),
                                 LibraryMap.Link(fromLabel: "ImageNet benchmark", toLabel: "heads", label: "measures")])
        XCTAssertEqual(map.edges(of: "a"), [e])
        XCTAssertEqual(map.edges(of: "c"), [])
        XCTAssertEqual(map.other(e, from: "a")?.title, "Beta")
        XCTAssertEqual(map.other(e, from: "b")?.title, "Alpha")
    }

    func testAConnectionStoredOnlyOnTheLaterSideReadsFromTheEarlierPaper() {
        var b = F.related
        b.external = [Self.link("heads", to: "a", "attn", "same idea")]
        let map = LibraryMap(papers: [Self.paper("a", "A"), Self.paper("b", "B")], maps: ["a": F.new, "b": b])
        XCTAssertEqual(map.edges.first?.links, [LibraryMap.Link(fromLabel: "attn", toLabel: "Attention heads", label: "same idea")])
    }

    func testEdgesWithMoreConnectionsComeFirst() {
        var a = F.new
        a.external = [Self.link("attn", to: "b", "heads", "one"),
                      Self.link("attn", to: "c", "x", "two"), Self.link("bench", to: "c", "y", "three")]
        let map = LibraryMap(papers: ["a", "b", "c"].map { Self.paper($0, $0) }, maps: ["a": a])
        XCTAssertEqual(map.edges.map(\.id), ["a↔c", "a↔b"])
    }

    func testPapersSitOnARingWithoutTouching() {
        let map = LibraryMap(papers: (0..<12).map { Self.paper("p\($0)", "Paper \($0)") }, maps: [:])
        let layout = LibraryMapLayout(map)
        let points = map.nodes.compactMap { layout.positions[$0.id] }
        XCTAssertEqual(points.count, 12)
        for (i, p) in points.enumerated() {
            XCTAssertGreaterThanOrEqual(p.x - LibraryMapLayout.nodeWidth / 2, 0)
            XCTAssertLessThanOrEqual(p.x + LibraryMapLayout.nodeWidth / 2, layout.width)
            XCTAssertGreaterThanOrEqual(p.y - LibraryMapLayout.nodeHeight / 2, 0)
            XCTAssertLessThanOrEqual(p.y + LibraryMapLayout.nodeHeight / 2, layout.height)
            for q in points[(i + 1)...] {
                XCTAssertTrue(abs(p.x - q.x) >= LibraryMapLayout.nodeWidth || abs(p.y - q.y) >= LibraryMapLayout.nodeHeight)
            }
        }
        XCTAssertEqual(layout.fitScale(width: layout.width * 2, height: layout.height * 2), 1)
        XCTAssertEqual(layout.fitScale(width: layout.width / 2, height: layout.height), 0.5, accuracy: 1e-9)
    }

    func testOutsidePapersJoinOnlyWhenConnectedAndSitOnAnOuterRing() {
        var a = F.new
        a.external = [Self.link("attn", to: "x", "heads", "same idea")]
        let map = LibraryMap(papers: [Self.paper("a", "A"), Self.paper("b", "B")], maps: ["a": a],
                             outside: [Self.paper("x", "Elsewhere"), Self.paper("y", "Unconnected"), Self.paper("a", "A")])
        XCTAssertEqual(map.nodes.map(\.id), ["a", "b", "x"])
        XCTAssertEqual(map.members.map(\.id), ["a", "b"])
        XCTAssertEqual(map.node("x")?.isOutside, true)
        let e = try! XCTUnwrap(map.edges.first)
        XCTAssertTrue(map.isOutside(e))
        XCTAssertEqual(LibraryMapPresentation.overview(map), "2 papers · 1 connected pair")

        let layout = LibraryMapLayout(map)
        func distance(_ id: String) -> Double {
            let p = layout.positions[id]!
            return hypot(p.x - layout.width / 2, p.y - layout.height / 2)
        }
        XCTAssertGreaterThan(distance("x"), distance("a") + 200)
        XCTAssertEqual(distance("a"), distance("b"), accuracy: 1e-9)

        let inside = LibraryMap(papers: [Self.paper("a", "A"), Self.paper("b", "B")], maps: ["a": a])
        XCTAssertEqual(inside.nodes.map(\.id), ["a", "b"], "without outside papers, the link to x is dropped")
        XCTAssertTrue(inside.edges.isEmpty)
    }

    func testPapersLinkedAmongThemselvesFormClustersThatSitTogether() {
        var a = F.new, c = F.new
        a.external = [Self.link("attn", to: "d", "heads", "one")]
        c.external = [Self.link("attn", to: "e", "heads", "two"), Self.link("bench", to: "f", "heads", "three"),
                      Self.link("attn", to: "x", "heads", "outside")]
        let papers = ["a", "b", "c", "d", "e", "f"].map { Self.paper($0, $0.uppercased()) }
        let map = LibraryMap(papers: papers, maps: ["a": a, "c": c], outside: [Self.paper("x", "X")])
        // c-e-f is the biggest cluster, then a-d; b stands alone, x is outside.
        XCTAssertEqual(map.nodes.map(\.id), ["c", "e", "f", "a", "d", "b", "x"])
        XCTAssertEqual(map.nodes.map(\.cluster), [0, 0, 0, 1, 1, nil, nil])
        XCTAssertEqual(map.edges.map { map.cluster(of: $0) }.sorted { ($0 ?? -1) < ($1 ?? -1) }, [nil, 0, 0, 1])
    }

    func testDraggedPapersStayOnTheCanvasWhereDropped() {
        let layout = LibraryMapLayout(LibraryMap(papers: [Self.paper("a", "A"), Self.paper("b", "B")], maps: [:]))
        let start = layout.positions["a"]!
        let p = layout.dragged(from: start, dx: 20, dy: -10, scale: 0.5)
        XCTAssertEqual(p, .init(x: start.x + 40, y: start.y - 20))
        let far = layout.dragged(from: start, dx: -1e6, dy: 1e6, scale: 1)
        XCTAssertEqual(far, .init(x: LibraryMapLayout.nodeWidth / 2, y: layout.height - LibraryMapLayout.nodeHeight / 2))
        let moved = layout.arranged(["a": p, "gone": p])
        XCTAssertEqual(moved.positions["a"], p)
        XCTAssertEqual(moved.positions["b"], layout.positions["b"])
        XCTAssertNil(moved.positions["gone"])
    }

    func testABigWindowStretchesTheRingsToFillIt() {
        let map = LibraryMap(papers: (0..<4).map { Self.paper("p\($0)", "P\($0)") }, maps: [:])
        let small = LibraryMapLayout(map)
        let big = LibraryMapLayout(map, minWidth: 2000, minHeight: 1200)
        XCTAssertEqual([big.width, big.height], [2000, 1200])
        XCTAssertEqual(big.fitScale(width: 2000, height: 1200), 1)
        let xs = map.nodes.map { big.positions[$0.id]!.x }, ys = map.nodes.map { big.positions[$0.id]!.y }
        // The ring reaches the canvas's edges, less the margin and half a box.
        XCTAssertEqual(xs.max()! + LibraryMapLayout.nodeWidth / 2, 2000 - 40, accuracy: 1)
        XCTAssertEqual(ys.min()! - LibraryMapLayout.nodeHeight / 2, 40, accuracy: 1)
        // A window smaller than the papers need doesn't squeeze them.
        XCTAssertEqual(LibraryMapLayout(map, minWidth: 10, minHeight: 10), small)
        // A paper dragged on a big window stays on the canvas when it shrinks.
        let dropped = small.arranged(["p0": .init(x: 1900, y: 1100)]).positions["p0"]!
        XCTAssertEqual(dropped, .init(x: small.width - LibraryMapLayout.nodeWidth / 2, y: small.height - LibraryMapLayout.nodeHeight / 2))
    }

    func testASinglePaperSitsInTheMiddle() {
        let layout = LibraryMapLayout(LibraryMap(papers: [Self.paper("a", "A")], maps: [:]))
        XCTAssertEqual(layout.positions["a"], .init(x: layout.width / 2, y: layout.height / 2))
    }

    func testWordingSaysWhyNothingConnects() {
        let none = LibraryMap(papers: [Self.paper("a", "A")], maps: [:])
        XCTAssertEqual(LibraryMapPresentation.emptyNote(none), "No paper here has a mind map yet. Create one from a paper's Manage menu.")
        let unlinked = LibraryMap(papers: [Self.paper("a", "A")], maps: ["a": F.new])
        XCTAssertEqual(LibraryMapPresentation.emptyNote(unlinked), "No connections yet. Papers connect when their mind maps share concepts.")
        var a = F.new
        a.external = [Self.link("attn", to: "b", "heads", "x")]
        let linked = LibraryMap(papers: [Self.paper("a", "A"), Self.paper("b", "B")], maps: ["a": a])
        XCTAssertNil(LibraryMapPresentation.emptyNote(linked))
        XCTAssertEqual(LibraryMapPresentation.overview(linked), "2 papers · 1 connected pair")
        XCTAssertEqual(LibraryMapPresentation.linkCount(1), "1 connection")
        XCTAssertEqual(LibraryMapPresentation.linkCount(3), "3 connections")
        XCTAssertEqual(LibraryMapPresentation.title("Neuro"), "Paper connections — Neuro")
        XCTAssertTrue(LibraryMapPresentation.canOpen(library: "lib"))
        XCTAssertFalse(LibraryMapPresentation.canOpen(library: nil))
    }

    @MainActor
    func testTheStoreReadsOnlyTheLibrarysPapersAndMaps() async {
        let storage = LocalStorage(root: Fixtures.tempDir())
        var a = F.new
        a.external = [Self.link("attn", to: "b", "heads", "same idea"), Self.link("attn", to: "out", "heads", "elsewhere")]
        for (id, inLibrary, map) in [("a", true, a), ("b", true, F.related), ("out", false, F.related)] {
            var p = Fixtures.paper(id: id, title: id)
            p.hasMindMap = true
            p.library = inLibrary ? "L" : nil
            await storage.save(p, K.paper(id))
            await storage.save(map, K.mindMap(id))
        }
        await storage.save([Library(id: "L", name: "Lib", icon: "folder", connectsAcross: false)], K.libraries)
        let store = AppStore(storage: storage, speech: FakeSpeechBackend())
        await waitUntil { store.papers.count == 3 && store.libraries.count == 1 }
        let map = await store.libraryMap("L")
        XCTAssertEqual(map.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(map.edges.map(\.id), ["a↔b"])
        XCTAssertEqual(map.edges.first?.links.map(\.label), ["same idea"])

        // Set to connect across, the paper outside joins the map, greyed.
        var form = LibraryForm(store.libraries[0])
        form.connectsAcross = true
        store.saveLibrary(form)
        let across = await store.libraryMap("L")
        XCTAssertEqual(across.nodes.map(\.id), ["a", "b", "out"])
        XCTAssertEqual(across.node("out")?.isOutside, true)
        XCTAssertEqual(across.edges.map(\.id), ["a↔b", "a↔out"])
    }
}
