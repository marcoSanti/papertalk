import XCTest
@testable import Papertalk

/// A mind map reply as the LLM would send it: each pillar with `parts` children.
enum MindMapFixtures {
    static func node(_ id: String, _ label: String, _ branch: String?, parent: String?) -> String {
        let b = branch.map { #""branch":"\#($0)","# } ?? ""
        let p = parent.map { #""\#($0)""# } ?? "null"
        return #"{"id":"\#(id)","label":"\#(label)",\#(b)"parent":\#(p),"description":"About \#(label).","core":"Key: \#(label)."}"#
    }

    static func reply(parts: Int = 2, extraNodes: [String] = [], links: String = "[]",
                      summary: String = "A plain summary.") -> String {
        var nodes: [String] = []
        for b in ["problem", "method", "evidence"] {
            nodes.append(node(b, b.capitalized, b, parent: nil))
            for i in 0..<parts { nodes.append(node("\(b)\(i)", "\(b) part \(i)", b, parent: b)) }
        }
        return #"{"summary":"\#(summary)","nodes":[\#((nodes + extraNodes).joined(separator: ","))],"links":\#(links)}"#
    }
}

final class MindMapParseTests: PapertalkTestCase {
    func testParsesTheThreePillarsAndTheirParts() throws {
        let map = try XCTUnwrap(MindMap.parse("Here you go:\n" + MindMapFixtures.reply(parts: 3)))
        XCTAssertEqual(map.nodes.count, 12)
        XCTAssertEqual(map.root(.problem)?.label, "Problem")
        XCTAssertEqual(map.children(of: "method").map(\.id), ["method0", "method1", "method2"])
        XCTAssertEqual(map.node("evidence1")?.core, "Key: evidence part 1.")
        XCTAssertTrue(map.isExpanded)
    }

    func testAPillarMissingMeansNoMap() {
        let reply = #"{"nodes":[{"id":"a","label":"A","branch":"problem","parent":null},{"id":"b","label":"B","branch":"method","parent":null}]}"#
        XCTAssertNil(MindMap.parse(reply))
        XCTAssertNil(MindMap.parse("no json here"))
        XCTAssertNil(MindMap.parse(#"{"concepts":[]}"#))
    }

    func testOnlyOnePartIsNotExpanded() throws {
        XCTAssertFalse(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(parts: 1))).isExpanded)
    }

    func testLongLabelsAreCutAtAWord() {
        XCTAssertEqual(MindMap.shortLabel("  Attention  "), "Attention")
        let cut = MindMap.shortLabel("A very long concept name that is really a whole sentence.")
        XCTAssertLessThanOrEqual(cut.count, MindMap.maxLabelLength)
        XCTAssertEqual(cut, "A very long concept name that…")
        XCTAssertEqual(MindMap.shortLabel(String(repeating: "x", count: 50)).count, MindMap.maxLabelLength)
    }

    func testOrphansAndStrayParentsHangUnderTheirBranch() throws {
        let extra = [
            MindMapFixtures.node("ghost", "Ghost parent", "method", parent: "nowhere"),
            MindMapFixtures.node("second", "Second root", "method", parent: nil),
            MindMapFixtures.node("inherits", "No branch", nil, parent: "problem0"),
            MindMapFixtures.node("cross", "Cross branch", "evidence", parent: "method0"),
            MindMapFixtures.node("problem0", "Duplicate id", "evidence", parent: nil),
            #"{"id":"","label":"No id"}"#, #"{"id":"nolabel","label":"  "}"#,
        ]
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(extraNodes: extra)))
        XCTAssertEqual(map.node("ghost")?.parent, "method")
        XCTAssertEqual(map.node("second")?.parent, "method")
        XCTAssertEqual(map.node("inherits")?.branch, .problem)
        XCTAssertEqual(map.node("inherits")?.parent, "problem0")
        XCTAssertEqual(map.node("cross")?.parent, "evidence")
        XCTAssertEqual(map.node("problem0")?.label, "problem part 0")      // the first of a duplicated id wins
        XCTAssertNil(map.node("nolabel"))
        XCTAssertEqual(map.nodes.count, 6 + 3 + 4)
    }

    func testParentCyclesAreBroken() throws {
        let extra = [MindMapFixtures.node("a", "A", "method", parent: "b"),
                     MindMapFixtures.node("b", "B", "method", parent: "a")]
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(extraNodes: extra)))
        // Every concept reaches its branch root.
        for n in map.nodes {
            var cur: String? = n.id, steps = 0
            while let c = cur, map.node(c)?.parent != nil, steps < 20 { cur = map.node(c)?.parent; steps += 1 }
            XCTAssertLessThan(steps, 20, n.id)
            XCTAssertEqual(cur.flatMap { map.node($0) }?.parent, nil)
        }
    }

    func testLinksToMissingConceptsSelfLinksAndTreeEdgesAreDropped() throws {
        let links = #"[{"from":"problem0","to":"method1","label":"solved by"},{"from":"method1","to":"problem0","label":"again"},"#
            + #"{"from":"problem0","to":"nowhere","label":"x"},{"from":"method","to":"method","label":"self"},"#
            + #"{"from":"method","to":"method0","label":"tree"},{"from":"evidence1","to":"method0","label":"validates"}]"#
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(links: links)))
        XCTAssertEqual(map.links, [MindMap.Link(from: "problem0", to: "method1", label: "solved by"),
                                   MindMap.Link(from: "evidence1", to: "method0", label: "validates")])
    }

    func testTheSummaryIsKeptAndOlderMapsStillLoad() throws {
        XCTAssertEqual(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(summary: "  It shows X.  "))).summary, "It shows X.")
        let none = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(summary: " ")))
        XCTAssertNil(none.summary)
        XCTAssertEqual(MindMapPresentation.summary(none), MindMapPresentation.noSummary)
        // A mindmap.json saved before summaries existed.
        let old = #"{"nodes":[{"id":"a","label":"A","branch":"problem","description":"d","core":"c"}],"links":[]}"#
        let map = try JSONDecoder().decode(MindMap.self, from: Data(old.utf8))
        XCTAssertNil(map.summary)
        XCTAssertEqual(map.nodes.count, 1)
    }

    func testRoundTrip() throws {
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply()))
        XCTAssertEqual(try JSONDecoder().decode(MindMap.self, from: JSONEncoder().encode(map)), map)
    }
}

final class MindMapLayoutTests: PapertalkTestCase {
    private func crowded() throws -> MindMap {
        // One busy branch: 10 parts, each with 3 details.
        var extra: [String] = []
        for i in 0..<10 {
            extra.append(MindMapFixtures.node("m\(i)", "Method step \(i)", "method", parent: "method"))
            for j in 0..<3 { extra.append(MindMapFixtures.node("m\(i)-\(j)", "Detail \(i).\(j)", "method", parent: "m\(i)")) }
        }
        return try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(extraNodes: extra,
                                                                    links: #"[{"from":"problem0","to":"m3","label":"answered by"}]"#)))
    }

    func testEveryConceptIsPlacedInsideTheCanvas() throws {
        let map = try crowded()
        let layout = MindMapLayout(map)
        XCTAssertEqual(Set(layout.positions.keys), Set(map.nodes.map(\.id) + [MindMapLayout.centerId]))
        for (id, p) in layout.positions {
            XCTAssertGreaterThanOrEqual(p.x - MindMapLayout.nodeWidth / 2, 0, id)
            XCTAssertGreaterThanOrEqual(p.y - MindMapLayout.nodeHeight / 2, 0, id)
            XCTAssertLessThanOrEqual(p.x + MindMapLayout.nodeWidth / 2, layout.width, id)
            XCTAssertLessThanOrEqual(p.y + MindMapLayout.nodeHeight / 2, layout.height, id)
        }
    }

    func testNoTwoNodesOverlap() throws {
        let layout = MindMapLayout(try crowded())
        let all = Array(layout.positions)
        for i in all.indices {
            for j in all.indices where j > i {
                let a = all[i].value, b = all[j].value
                let overlap = abs(a.x - b.x) < MindMapLayout.nodeWidth && abs(a.y - b.y) < MindMapLayout.nodeHeight
                XCTAssertFalse(overlap, "\(all[i].key) overlaps \(all[j].key)")
            }
        }
    }

    func testBranchesSitInTheirOwnSectors() throws {
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply()))
        let layout = MindMapLayout(map)
        let c = try XCTUnwrap(layout.positions[MindMapLayout.centerId])
        let problem = try XCTUnwrap(layout.positions["problem"]), method = try XCTUnwrap(layout.positions["method"])
        let evidence = try XCTUnwrap(layout.positions["evidence"])
        XCTAssertTrue(problem.x < c.x && problem.y < c.y)     // up-left
        XCTAssertTrue(method.x > c.x && method.y < c.y)       // up-right
        XCTAssertGreaterThan(evidence.y, c.y)                  // below
        XCTAssertEqual(layout.depth["problem"], 1)
        XCTAssertEqual(layout.depth["problem0"], 2)
    }

    func testFitScaleShowsTheWholeMap() throws {
        let layout = MindMapLayout(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(parts: 3))))
        let fit = layout.fitScale(width: 700, height: 600)
        XCTAssertLessThan(fit, 1)
        XCTAssertLessThanOrEqual(layout.width * fit, 700 + 0.001)
        XCTAssertLessThanOrEqual(layout.height * fit, 600 + 0.001)
        XCTAssertEqual(layout.fitScale(width: 1e6, height: 1e6), 1)      // never enlarged
        XCTAssertEqual(layout.fitScale(width: 1, height: 1), MindMapLayout.minScale)
        XCTAssertEqual(MindMapLayout.clampScale(9), MindMapLayout.maxScale)
    }

    func testPanningFollowsThePointerAndStopsAtTheEdges() {
        typealias P = MindMapLayout.Point
        let content = (width: 2000.0, height: 1500.0), viewport = (width: 800.0, height: 600.0)
        func pan(_ x: Double, _ y: Double, _ dx: Double, _ dy: Double) -> P {
            MindMapLayout.panned(from: P(x: x, y: y), dx: dx, dy: dy, content: content, viewport: viewport)
        }
        XCTAssertEqual(pan(500, 400, 100, -50), P(x: 400, y: 450))      // drag right/up: see more left/down
        XCTAssertEqual(pan(50, 50, 300, 300), P(x: 0, y: 0))            // stops at the top-left
        XCTAssertEqual(pan(1100, 800, -500, -500), P(x: 1200, y: 900))  // and at the bottom-right
        // A map smaller than the window doesn't move.
        XCTAssertEqual(MindMapLayout.panned(from: P(x: 0, y: 0), dx: -200, dy: -200,
                                            content: (500, 400), viewport: viewport), P(x: 0, y: 0))
    }

    func testEdgesCanBeSelectedByAHandleHalfwayAlong() throws {
        let links = #"[{"from":"problem0","to":"method1","label":"solved by"}]"#
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(links: links)))
        let layout = MindMapLayout(map)
        // The paper's own edges to the main concepts aren't selectable.
        XCTAssertFalse(layout.selectableEdges.contains { $0.from == MindMapLayout.centerId })
        XCTAssertEqual(layout.selectableEdges.count, 6 + 1)

        let tree = try XCTUnwrap(layout.selectableEdges.first { $0.from == "method" && $0.to == "method0" })
        let a = try XCTUnwrap(layout.positions["method"]), b = try XCTUnwrap(layout.positions["method0"])
        XCTAssertNil(layout.control(tree))
        XCTAssertEqual(layout.handle(tree), MindMapLayout.Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))

        // A link bows away from the centre, and its handle sits on the curve, off the straight line.
        let link = try XCTUnwrap(layout.selectableEdges.first { $0.label != nil })
        XCTAssertEqual(link.id, "problem0→method1")
        let h = try XCTUnwrap(layout.handle(link))
        let p = try XCTUnwrap(layout.positions["problem0"]), q = try XCTUnwrap(layout.positions["method1"])
        let c = try XCTUnwrap(layout.positions[MindMapLayout.centerId])
        let straight = MindMapLayout.Point(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        XCTAssertGreaterThan(hypot(h.x - c.x, h.y - c.y), hypot(straight.x - c.x, straight.y - c.y) + 20)
    }

    func testALinkAcrossTheCentreKeepsItsHandleClearOfThePaperNode() throws {
        // problem0 (up-left) to evidence1 (down): the straight line passes near the centre.
        let links = #"[{"from":"problem0","to":"evidence1","label":"shown by"},{"from":"method0","to":"evidence0","label":"tested by"}]"#
        let layout = MindMapLayout(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(links: links))))
        let c = try XCTUnwrap(layout.positions[MindMapLayout.centerId])
        for link in layout.selectableEdges where link.label != nil {
            let h = try XCTUnwrap(layout.handle(link))
            let clear = abs(h.x - c.x) > MindMapLayout.nodeWidth / 2 || abs(h.y - c.y) > MindMapLayout.nodeHeight / 2
            XCTAssertTrue(clear, "\(link.id) handle under the paper node")
        }
    }

    func testLinkLabelsDontCoverNodes() throws {
        // problem1 → method0 bowed outward used to put "fixes" right on top of problem2.
        let links = #"[{"from":"problem1","to":"method0","label":"fixes"},{"from":"problem0","to":"evidence1","label":"shown by"},"#
            + #"{"from":"method2","to":"evidence0","label":"tested by"}]"#
        let layout = MindMapLayout(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(parts: 3, links: links))))
        for link in layout.selectableEdges where link.label != nil {
            XCTAssertFalse(layout.labelOverlapsNode(try XCTUnwrap(layout.handle(link))), link.id)
        }
    }

    func testLinkLabelsStayInsideTheCanvas() throws {
        // Two concepts on the outer ring of neighbouring branches: their link bows outward.
        let links = #"[{"from":"problem1","to":"method0","label":"fixes"},{"from":"evidence0","to":"evidence1","label":"x"}]"#
        let layout = MindMapLayout(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(links: links))))
        for link in layout.selectableEdges where link.label != nil {
            let h = try XCTUnwrap(layout.handle(link))
            XCTAssertGreaterThanOrEqual(h.x - MindMapLayout.linkLabelWidth / 2, 0, link.id)
            XCTAssertGreaterThanOrEqual(h.y - MindMapLayout.linkLabelHeight / 2, 0, link.id)
            XCTAssertLessThanOrEqual(h.x + MindMapLayout.linkLabelWidth / 2, layout.width, link.id)
            XCTAssertLessThanOrEqual(h.y + MindMapLayout.linkLabelHeight / 2, layout.height, link.id)
        }
    }

    func testEdgesJoinTheCentreTheTreeAndTheLinks() throws {
        let map = try crowded()
        let layout = MindMapLayout(map)
        XCTAssertEqual(layout.edges.count, 3 + map.nodes.filter { $0.parent != nil }.count + map.links.count)
        XCTAssertTrue(layout.edges.contains(MindMapLayout.Edge(from: MindMapLayout.centerId, to: "evidence", label: nil)))
        XCTAssertTrue(layout.edges.contains(MindMapLayout.Edge(from: "problem0", to: "m3", label: "answered by")))
    }
}

final class MindMapPresentationTests: PapertalkTestCase {
    func testConnectionsListParentPartsAndLinks() throws {
        let links = #"[{"from":"evidence0","to":"method0","label":"validates"},{"from":"method0","to":"problem1","label":""}]"#
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(links: links)))
        XCTAssertEqual(MindMapPresentation.connections(map, of: "method0").map(\.relation), ["Part of", "validates", "Linked"])
        XCTAssertEqual(MindMapPresentation.connections(map, of: "method").map(\.relation), ["Includes", "Includes"])
        XCTAssertEqual(MindMapPresentation.connections(map, of: "method").map(\.label), ["method part 0", "method part 1"])
        XCTAssertEqual(MindMapPresentation.connections(map, of: "nope"), [])
    }

    func testAnEdgeShowsBothConceptsTopToBottom() throws {
        let links = #"[{"from":"evidence0","to":"method0","label":"validates"},{"from":"method1","to":"problem1","label":""}]"#
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(links: links)))
        let layout = MindMapLayout(map)
        func detail(_ from: String, _ to: String) -> MindMapPresentation.EdgeDetail? {
            layout.selectableEdges.first { $0.from == from && $0.to == to }.flatMap { MindMapPresentation.edgeDetail(map, $0) }
        }
        let tree = try XCTUnwrap(detail("method", "method0"))
        XCTAssertEqual([tree.top.id, tree.bottom.id, tree.relation], ["method", "method0", "includes"])
        let link = try XCTUnwrap(detail("evidence0", "method0"))
        XCTAssertEqual([link.top.id, link.bottom.id, link.relation], ["evidence0", "method0", "validates"])
        XCTAssertEqual(MindMapPresentation.edgeHelp(link), "evidence part 0 validates method part 0")
        XCTAssertEqual(try XCTUnwrap(detail("method1", "problem1")).relation, "linked to")
        XCTAssertNil(MindMapPresentation.edgeDetail(map, MindMapLayout.Edge(from: "x", to: "method", label: nil)))
    }

    func testWordingAndTiers() throws {
        XCTAssertEqual(MindMap.Branch.allCases.map(MindMapPresentation.branchTitle),
                       ["The problem", "The approach", "The demonstration"])
        XCTAssertEqual(Set(MindMap.Branch.allCases.map(MindMapPresentation.branchIcon)).count, 3)
        let layout = MindMapLayout(try XCTUnwrap(MindMap.parse(MindMapFixtures.reply())))
        XCTAssertEqual(MindMapPresentation.tier(layout, MindMapLayout.centerId), .paper)
        XCTAssertEqual(MindMapPresentation.tier(layout, "method"), .main)
        XCTAssertEqual(MindMapPresentation.tier(layout, "method1"), .detail)
    }

    func testManageRowAndAvailability() {
        var p = Fixtures.paper(id: "x")
        XCTAssertFalse(PaperPresentation.hasMindMap(p))
        XCTAssertEqual(PaperPresentation.mindMapRow(p, drawing: false).title, "Create mind map")
        XCTAssertEqual(PaperPresentation.mindMapRow(p, drawing: true).title, "Drawing mind map…")
        p.hasMindMap = true
        XCTAssertTrue(PaperPresentation.hasMindMap(p))
        XCTAssertEqual(PaperPresentation.mindMapRow(p, drawing: false).title, "Redraw mind map")
        p.hasPdf = true
        p.state = "done"
        XCTAssertTrue(PaperPresentation.canCreateMindMap(p, llmConfigured: true, drawing: false))
        XCTAssertFalse(PaperPresentation.canCreateMindMap(p, llmConfigured: false, drawing: false))
        XCTAssertFalse(PaperPresentation.canCreateMindMap(p, llmConfigured: true, drawing: true))
        p.state = "running"
        XCTAssertFalse(PaperPresentation.canCreateMindMap(p, llmConfigured: true, drawing: false))
        p.state = "done"; p.hasPdf = false
        XCTAssertFalse(PaperPresentation.canCreateMindMap(p, llmConfigured: true, drawing: false))
    }
}

final class MindMapPipelineTests: PapertalkTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ v: String) { lock.withLock { items.append(v) } }
        var all: [String] { lock.withLock { items } }
    }

    private func pipeline() -> LocalPipeline { LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m") }

    func testAsksAgainWhenAPillarIsNotBrokenDown() async throws {
        let sent = Box()
        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            sent.append(text)
            let retry = text.contains("break each of the three main concepts")
            return (200, MockLLM.chatReply(MindMapFixtures.reply(parts: retry ? 3 : 1)))
        }
        var p = pipeline()
        p.prompts.mindMap = "MAP-X"
        let map = try await p.mindMap(title: "T", text: "paper text")
        XCTAssertEqual(sent.all.count, 2)
        XCTAssertTrue(sent.all[0].contains("MAP-X") && sent.all[0].contains(#""branch": "problem"|"method"|"evidence""#))
        XCTAssertTrue(map.isExpanded)
        XCTAssertEqual(map.nodes.count, 12)
    }

    func testOneGoodReplyIsEnough() async throws {
        let calls = Box()
        MockLLM.install { _ in calls.append("x"); return (200, MockLLM.chatReply(MindMapFixtures.reply())) }
        _ = try await pipeline().mindMap(title: "T", text: "x")
        XCTAssertEqual(calls.all.count, 1)
    }

    func testKeepsAnUnexpandedMapRatherThanNothing() async throws {
        MockLLM.install { request in
            let retry = MockLLM.allText(in: request).contains("break each of the three main concepts")
            return (200, MockLLM.chatReply(retry ? "sorry" : MindMapFixtures.reply(parts: 1)))
        }
        let map = try await pipeline().mindMap(title: "T", text: "x")
        XCTAssertFalse(map.isExpanded)
    }

    func testUnusableRepliesThrow() async {
        MockLLM.install { _ in (200, MockLLM.chatReply("no map")) }
        do {
            _ = try await pipeline().mindMap(title: "T", text: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("mind map"))
        }
    }
}
