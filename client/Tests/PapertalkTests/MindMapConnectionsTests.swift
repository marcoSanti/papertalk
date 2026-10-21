// Tests of connecting a new mind map to other papers' maps: the local shortlist, the LLM's
// verdict, mirroring onto the other maps, drawing them, and the whole run in the store.

import XCTest
@testable import Papertalk

/// Small maps whose concepts share (or don't share) distinctive words.
enum ConnectionFixtures {
    static func node(_ id: String, _ label: String, _ core: String, branch: MindMap.Branch = .method, parent: String?) -> MindMap.Node {
        MindMap.Node(id: id, label: label, branch: branch, parent: parent, description: "", core: core)
    }

    /// The three roots plus `extra` concepts under the method root.
    static func map(_ extra: [(String, String, String)]) -> MindMap {
        MindMap(nodes: [node("problem", "Problem", "", branch: .problem, parent: nil),
                        node("method", "Method", "", parent: nil),
                        node("evidence", "Evidence", "", branch: .evidence, parent: nil)]
                    + extra.map { node($0.0, $0.1, $0.2, parent: "method") },
                links: [])
    }

    static let new = map([("attn", "Sparse attention", "Sparse attention heads cut transformer memory."),
                          ("bench", "ImageNet benchmark", "Accuracy measured on ImageNet validation.")])
    static let related = map([("heads", "Attention heads", "Pruning sparse attention heads in transformers.")])
    static let unrelated = map([("soil", "Soil moisture", "Rainfall drives soil moisture in farmland.")])
}

final class MindMapConnectionsTests: PapertalkTestCase {
    typealias F = ConnectionFixtures

    func testWordsDropStopwordsShortWordsAndPlurals() {
        XCTAssertEqual(MindMapConnections.words("The transformers use attention heads, at scale"),
                       ["transformer", "attention", "head", "scale"])
    }

    func testShortlistsConceptsThatShareRareWordsOnly() {
        let c = MindMapConnections.candidates(for: F.new, among: ["r": F.related, "u": F.unrelated])
        XCTAssertEqual(c.first?.from, "attn")
        XCTAssertEqual(c.first?.paperId, "r")
        XCTAssertEqual(c.first?.nodeId, "heads")
        XCTAssertFalse(c.contains { $0.paperId == "u" })
        XCTAssertTrue(MindMapConnections.candidates(for: F.new, among: [:]).isEmpty)
    }

    func testTheShortlistIsBoundedHoweverBigTheLibrary() {
        var others: [String: MindMap] = [:]
        for i in 0..<60 { others["p\(i)"] = F.related }
        let c = MindMapConnections.candidates(for: F.new, among: others)
        XCTAssertLessThanOrEqual(c.count, MindMapConnections.maxPairs)
        XCTAssertLessThanOrEqual(Set(c.map(\.paperId)).count, MindMapConnections.maxPapers)
        XCTAssertLessThanOrEqual(c.filter { $0.from == "attn" }.count, MindMapConnections.perConcept)
    }

    func testTheVerdictKeepsConfirmedPairsOnly() {
        let others = ["r": F.related]
        let candidates = MindMapConnections.candidates(for: F.new, among: others)
        let raw = #"Sure: {"links": [{"pair": 1, "label": "prunes the same"}, {"pair": "1", "label": "again"}, {"pair": 99, "label": "x"}, {"pair": 1, "label": ""}]}"#
        let links = MindMapConnections.parse(raw, candidates: candidates, others: others, titles: ["r": "Related paper"])
        XCTAssertEqual(links, [MindMap.ExternalLink(from: "attn", paperId: "r", paperTitle: "Related paper",
                                                    nodeId: "heads", nodeLabel: "Attention heads", label: "prunes the same")])
        XCTAssertTrue(MindMapConnections.parse("no", candidates: candidates, others: others, titles: [:]).isEmpty)
        let list = MindMapConnections.pairList(candidates, map: F.new, others: others, titles: ["r": "Related paper"])
        XCTAssertTrue(list.hasPrefix(#"1. THIS PAPER: Sparse attention"#))
        XCTAssertTrue(list.contains(#""Related paper": Attention heads"#))
    }

    func testMirroringReplacesTheOtherSideAndOnlyReturnsChangedMaps() {
        var stale = F.related
        stale.external = [MindMap.ExternalLink(from: "heads", paperId: "new", paperTitle: "Old title", nodeId: "gone", nodeLabel: "Gone", label: "old"),
                          MindMap.ExternalLink(from: "heads", paperId: "third", paperTitle: "T", nodeId: "x", nodeLabel: "X", label: "kept")]
        let link = MindMap.ExternalLink(from: "attn", paperId: "r", paperTitle: "R", nodeId: "heads", nodeLabel: "Attention heads", label: "same idea")
        let changed = MindMapConnections.mirrored([link], of: "new", title: "New paper", map: F.new,
                                                  into: ["r": stale, "u": F.unrelated])
        XCTAssertEqual(Array(changed.keys), ["r"])
        XCTAssertEqual(changed["r"]?.externalLinks, [
            stale.externalLinks[1],
            MindMap.ExternalLink(from: "heads", paperId: "new", paperTitle: "New paper", nodeId: "attn", nodeLabel: "Sparse attention", label: "same idea"),
        ])
        // A redraw that finds nothing clears the old side.
        XCTAssertEqual(MindMapConnections.mirrored([], of: "new", title: "New", map: F.new, into: ["r": stale])["r"]?.externalLinks,
                       [stale.externalLinks[1]])
    }

    func testOlderMapsDecodeAndDeletingAConceptDropsItsConnections() throws {
        let old = try JSONDecoder().decode(MindMap.self, from: Data(#"{"nodes":[],"links":[]}"#.utf8))
        XCTAssertNil(old.external)
        var m = F.new
        m.external = [MindMap.ExternalLink(from: "attn", paperId: "r", paperTitle: "R", nodeId: "heads", nodeLabel: "H", label: "l")]
        XCTAssertEqual(try JSONDecoder().decode(MindMap.self, from: JSONEncoder().encode(m)), m)
        var deleted = m
        deleted.deleteExternal(from: "attn", paperId: "r", nodeId: "heads")
        XCTAssertTrue(deleted.externalLinks.isEmpty)
        m.deleteNode("attn")
        XCTAssertTrue(m.externalLinks.isEmpty)
    }

    func testOtherPapersConceptsAreDrawnOutsideTheMapWithoutOverlapping() throws {
        var m = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply(parts: 3)))
        m.external = (0..<6).map { MindMap.ExternalLink(from: "method0", paperId: "p\($0)", paperTitle: "P\($0)",
                                                         nodeId: "n", nodeLabel: "N\($0)", label: "rel") }
            + [MindMap.ExternalLink(from: "missing", paperId: "q", paperTitle: "Q", nodeId: "n", nodeLabel: "N", label: "rel")]
        let layout = MindMapLayout(m)
        let ext = layout.positions.keys.filter(MindMapLayout.isExternal)
        XCTAssertEqual(ext.count, 6, "a link from a missing concept isn't drawn")
        let center = try XCTUnwrap(layout.positions[MindMapLayout.centerId])
        let inner = m.nodes.compactMap { layout.positions[$0.id] }.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        let all = Array(layout.positions.values)
        for id in ext {
            let p = try XCTUnwrap(layout.positions[id])
            XCTAssertGreaterThan(hypot(p.x - center.x, p.y - center.y), inner)
            XCTAssertTrue(p.x - MindMapLayout.nodeWidth / 2 >= 0 && p.x + MindMapLayout.nodeWidth / 2 <= layout.width)
            XCTAssertTrue(p.y - MindMapLayout.nodeHeight / 2 >= 0 && p.y + MindMapLayout.nodeHeight / 2 <= layout.height)
            for q in all where q != p {
                XCTAssertFalse(abs(q.x - p.x) < MindMapLayout.nodeWidth && abs(q.y - p.y) < MindMapLayout.nodeHeight, "overlap at \(id)")
            }
            XCTAssertEqual(MindMapPresentation.tier(layout, id), .external)
        }
        XCTAssertTrue(layout.edges.contains { $0.from == "method0" && $0.to == MindMapLayout.externalId(paperId: "p0", nodeId: "n") })
    }

    func testThePanelDescribesAnotherPapersConcept() {
        var m = F.new
        m.external = [MindMap.ExternalLink(from: "attn", paperId: "r", paperTitle: "R", nodeId: "heads", nodeLabel: "Attention heads", label: "same idea")]
        let id = MindMapLayout.externalId(paperId: "r", nodeId: "heads")
        XCTAssertEqual(MindMapPresentation.external(m, id),
                       .init(paperId: "r", paperTitle: "R", nodeId: "heads", label: "Attention heads",
                             connections: [.init(id: "attn", label: "Sparse attention", relation: "same idea")]))
        XCTAssertNil(MindMapPresentation.external(m, "attn"))
        XCTAssertTrue(MindMapPresentation.connections(m, of: "attn").contains { $0.id == id && $0.relation == "same idea" })
    }

    func testThePipelineAsksOnlyAboutTheShortlist() async throws {
        let calls = LockedCount()
        MockLLM.install { request in
            calls.add()
            XCTAssertTrue(MockLLM.allText(in: request).contains(#"{"links": [{"pair": number, "label": string}]}"#))
            return (200, MockLLM.chatReply(#"{"links":[{"pair":1,"label":"same heads"}]}"#))
        }
        let p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        let none = try await p.mindMapConnections(title: "T", map: F.new, candidates: [], others: [:], titles: [:])
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(calls.value, 0)
        let others = ["r": F.related]
        let links = try await p.mindMapConnections(title: "T", map: F.new, candidates: MindMapConnections.candidates(for: F.new, among: others),
                                                   others: others, titles: ["r": "R"])
        XCTAssertEqual(links.map(\.label), ["same heads"])
        XCTAssertEqual(calls.value, 1)
    }
}

/// A thread-safe call counter for mock handlers.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// The whole run: drawing a map connects it to the library and mirrors it onto the other map.
@MainActor
final class MindMapConnectionsStoreTests: PapertalkTestCase {
    func testANewMapIsConnectedAndMirrored() async throws {
        let storage = LocalStorage(root: Fixtures.tempDir())
        var old = Fixtures.paper(id: "old", title: "Old paper")
        old.hasMindMap = true
        await storage.save(old, K.paper("old"))
        await storage.save(ConnectionFixtures.related, K.mindMap("old"))
        await storage.save(Fixtures.paper(id: "new", title: "New paper"), K.paper("new"))
        try await storage.write(K.pdf("new"), Fixtures.pdf(lines: ["Sparse attention heads"]))
        let store = AppStore(storage: storage, speech: FakeSpeechBackend())
        await waitUntil { store.papers.count == 2 }
        store.llm.baseUrl = "http://mock.local/v1"

        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            if text.contains("PAIRS:") { return (200, MockLLM.chatReply(#"{"links":[{"pair":1,"label":"same heads"}]}"#)) }
            // The new paper's map: the fixture's concepts.
            let nodes = ConnectionFixtures.new.nodes.map { n in
                #"{"id":"\#(n.id)","label":"\#(n.label)","branch":"\#(n.branch.rawValue)","parent":\#(n.parent.map { "\"\($0)\"" } ?? "null"),"description":"","core":"\#(n.core)"}"#
            }
            return (200, MockLLM.chatReply(#"{"summary":"S","nodes":[\#(nodes.joined(separator: ","))],"links":[]}"#))
        }
        store.createMindMap("new")
        await waitUntil(timeout: 5) {
            await storage.exists(MindMap.self, K.mindMap("old"))?.externalLinks.isEmpty == false
        }
        let savedNew = await storage.exists(MindMap.self, K.mindMap("new"))
        let mine = try XCTUnwrap(savedNew)
        XCTAssertEqual(mine.externalLinks.map(\.paperId), ["old"])
        XCTAssertEqual(mine.externalLinks.first?.paperTitle, "Old paper")
        let savedOld = await storage.exists(MindMap.self, K.mindMap("old"))
        let theirs = try XCTUnwrap(savedOld)
        XCTAssertEqual(theirs.externalLinks.map(\.paperId), ["new"])
        XCTAssertEqual(theirs.externalLinks.first?.nodeId, "attn")

        // Connections to a paper that left the library aren't shown.
        var withGone = theirs
        withGone.external?.append(MindMap.ExternalLink(from: "heads", paperId: "nowhere", paperTitle: "X", nodeId: "n", nodeLabel: "N", label: "l"))
        await storage.save(withGone, K.mindMap("old"))
        let shown = await store.mindMap(for: "old")
        XCTAssertEqual(shown?.externalLinks.map(\.paperId), ["new"])
    }

    // MARK: both sides stay in step

    private typealias F = ConnectionFixtures
    private static let link = MindMap.ExternalLink(from: "attn", paperId: "b", paperTitle: "Paper B",
                                                   nodeId: "heads", nodeLabel: "Attention heads", label: "same heads")

    /// Papers "a" (the `new` fixture) and "b" (`related`) with maps on disk, and the store.
    private func twoPapers() async -> (AppStore, LocalStorage) {
        let storage = LocalStorage(root: Fixtures.tempDir())
        for (id, title, map) in [("a", "Paper A", F.new), ("b", "Paper B", F.related)] {
            var p = Fixtures.paper(id: id, title: title)
            p.hasMindMap = true
            await storage.save(p, K.paper(id))
            await storage.save(map, K.mindMap(id))
        }
        let store = AppStore(storage: storage, speech: FakeSpeechBackend())
        await waitUntil { store.papers.count == 2 }
        return (store, storage)
    }

    private func links(_ storage: LocalStorage, _ id: String) async -> [MindMap.ExternalLink] {
        await storage.exists(MindMap.self, K.mindMap(id))?.externalLinks ?? []
    }

    func testSavingAConnectionAddsItOnTheOtherPaperToo() async {
        let (store, storage) = await twoPapers()
        var a = F.new
        a.external = [Self.link]
        store.saveMindMap("a", a)
        await waitUntil { await self.links(storage, "b").count == 1 }
        let back = await links(storage, "b")
        XCTAssertEqual(back, [MindMap.ExternalLink(from: "heads", paperId: "a", paperTitle: "Paper A",
                                                   nodeId: "attn", nodeLabel: "Sparse attention", label: "same heads")])
        XCTAssertEqual(store.mindMapRevision["a"], 1)
        XCTAssertEqual(store.mindMapRevision["b"], 1)
    }

    func testDeletingAConnectionOrItsConceptOnOneSideDeletesTheOtherSide() async {
        let (store, storage) = await twoPapers()
        var a = F.new
        a.external = [Self.link]
        store.saveMindMap("a", a)
        await waitUntil { await self.links(storage, "b").count == 1 }

        // Deleted from B's window: A loses it too.
        var b = await storage.exists(MindMap.self, K.mindMap("b"))!
        b.deleteExternal(from: "heads", paperId: "a", nodeId: "attn")
        store.saveMindMap("b", b)
        await waitUntil { await self.links(storage, "a").isEmpty }
        let afterDelete = await links(storage, "a")
        XCTAssertTrue(afterDelete.isEmpty)

        // Deleting the concept on A takes B's side with it.
        store.saveMindMap("a", a)
        await waitUntil { await self.links(storage, "b").count == 1 }
        a.deleteNode("attn")
        store.saveMindMap("a", a)
        await waitUntil { await self.links(storage, "b").isEmpty }
        let afterConcept = await links(storage, "b")
        XCTAssertTrue(afterConcept.isEmpty)
    }

    func testAConnectionToAConceptThatIsGoneIsDroppedOnSave() async {
        let (store, storage) = await twoPapers()
        var a = F.new
        a.external = [Self.link, MindMap.ExternalLink(from: "attn", paperId: "b", paperTitle: "Paper B",
                                                      nodeId: "redrawn-away", nodeLabel: "X", label: "x")]
        store.saveMindMap("a", a)
        await waitUntil { await self.links(storage, "b").count == 1 }
        let mine = await links(storage, "a")
        XCTAssertEqual(mine, [Self.link])
    }

    func testARedrawThatFindsNothingClearsTheOtherSide() async {
        let (store, storage) = await twoPapers()
        var b = F.related
        b.external = [MindMap.ExternalLink(from: "heads", paperId: "a", paperTitle: "Paper A", nodeId: "attn",
                                           nodeLabel: "Sparse attention", label: "old")]
        await storage.save(b, K.mindMap("b"))
        // A's new drawing has no connections; B is involved because it still points at A.
        store.saveMindMap("a", F.new, involving: ["b"])
        await waitUntil { await self.links(storage, "b").isEmpty }
        let left = await links(storage, "b")
        XCTAssertTrue(left.isEmpty)
    }

    func testAnImportedPaperFileGetsItsConnectionsOnBothSides() async throws {
        let (store, storage) = await twoPapers()
        var a = F.new
        a.external = [Self.link]
        await storage.save(a, K.mindMap("a"))
        await storage.save(Fixtures.transcript([("Jordan", "Hi")]), K.transcript("a"))
        let bundle = Fixtures.tempDir().appendingPathComponent("A.papertalk")
        await store.exportPaper("a", to: bundle, includePDF: false)
        let imported = await store.importPaper(from: bundle)
        let copy = try XCTUnwrap(imported)
        await waitUntil { await self.links(storage, "b").contains { $0.paperId == copy } }
        let back = await links(storage, "b")
        XCTAssertEqual(back.map(\.paperId), [copy])
    }
}
