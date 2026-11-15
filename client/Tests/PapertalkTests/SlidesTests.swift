// Tests of slide decks: reading slides (with the LLM describing picture slides), the Slides
// library kept apart from the papers, and the import sheet's deck toggle.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(PDFKit)
import PDFKit
#endif
import XCTest
@testable import Papertalk

/// `LocalPipeline`'s slide steps: which slides are described, and how a deck reads as text.
final class SlidesPipelineTests: PapertalkTestCase {
    override func tearDown() {
        MockLLM.uninstall()
        super.tearDown()
    }

    func testOnlySlidesWithLittleTextAreDescribed() {
        XCTAssertTrue(LocalPipeline.needsDescription("  Results \n"))
        XCTAssertFalse(LocalPipeline.needsDescription(String(repeating: "word ", count: 80)))
    }

    func testSlidePageAndDeckText() {
        XCTAssertEqual(LocalPipeline.slidePage(2, text: " Results ", description: " A chart. "),
                       "Slide 2\nResults\n[What the slide shows: A chart.]")
        XCTAssertEqual(LocalPipeline.slidePage(1, text: "Intro", description: nil), "Slide 1\nIntro")
        XCTAssertEqual(LocalPipeline.slidesText(["Slide 1\nA", "Slide 2\nB"], note: " NOTE \n"), "NOTE\n\nSlide 1\nA\n\nSlide 2\nB")
        XCTAssertEqual(LocalPipeline.slidesText([], note: "NOTE"), "")
    }

    #if os(macOS)
    /// `Fixtures.pdf` repeated `count` times, one page each.
    private func deck(_ count: Int) -> Data {
        let doc = PDFDocument(data: Fixtures.pdf(lines: ["Accuracy over time"]))!
        for i in 1..<count { doc.insert(doc.page(at: 0)!.copy() as! PDFPage, at: i) }
        return doc.dataRepresentation()!
    }

    func testPictureSlidesAreSentAsImagesAndDescribed() async throws {
        nonisolated(unsafe) var sent: [[String: Any]] = []
        MockLLM.install { request in
            let obj = try? JSONSerialization.jsonObject(with: MockLLM.bodyData(request) ?? Data()) as? [String: Any]
            sent = obj?["messages"] as? [[String: Any]] ?? []
            return (200, MockLLM.chatReply(" A line chart: accuracy rises from 60% to 90%. "))
        }
        let pages = await LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "", model: "m").slidePages(deck(1))
        XCTAssertEqual(pages, ["Slide 1\nAccuracy over time\n[What the slide shows: A line chart: accuracy rises from 60% to 90%.]"])
        XCTAssertEqual(sent.first?["content"] as? String, PromptSettings.defaults.slideDescription)
        let parts = try XCTUnwrap(sent.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "Extracted text:\nAccuracy over time")
        let url = (parts.last?["image_url"] as? [String: Any])?["url"] as? String ?? ""
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
        XCTAssertNotNil(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
    }

    func testAModelThatCantReadImagesIsAskedOnce() async {
        nonisolated(unsafe) var calls = 0
        MockLLM.install { _ in calls += 1; return (400, Data()) }
        let pages = await LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "", model: "m").slidePages(deck(3))
        XCTAssertEqual(pages, (1...3).map { "Slide \($0)\nAccuracy over time" }, "every slide keeps its text")
        XCTAssertEqual(calls, 1, "after the first failure the rest of the deck isn't sent")
    }
    #endif
}

/// Decks live in the Slides library only, and the store reads their saved slides.
@MainActor
final class SlidesStoreTests: PapertalkTestCase {
    nonisolated(unsafe) private var storage: LocalStorage!

    override func setUp() {
        super.setUp()
        storage = LocalStorage(root: Fixtures.tempDir())
    }

    override func tearDown() {
        MockLLM.uninstall()
        super.tearDown()
    }

    private func deck(_ id: String, title: String = "Talk") -> Paper {
        var d = Fixtures.paper(id: id, tags: ["nlp"], favorite: true, authors: ["Ada Lovelace"])
        d.title = title
        d.kind = Paper.slidesKind
        return d
    }

    private func makeStore(_ papers: [Paper]) async -> AppStore {
        for p in papers { await storage.save(p, K.paper(p.id)) }
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == papers.count }
        return store
    }

    func testDecksAreKeptApartFromPapers() async {
        var paper = Fixtures.paper(id: "a", tags: ["nlp"], authors: ["Ada Lovelace"])
        paper.title = "Talk"
        let store = await makeStore([paper, deck("d")])
        XCTAssertTrue(store.papers["d"]?.isSlides == true, "the kind is saved and read back")

        XCTAssertEqual(store.filteredPapers().map(\.id), ["a"])
        XCTAssertEqual(store.sidebarCount(.all), 1)
        XCTAssertEqual(store.sidebarCount(.favorites), 0)
        XCTAssertEqual(store.tagCounts.map(\.1), [1])
        XCTAssertEqual(store.papersByAuthor["Ada Lovelace"]?.map(\.id), ["a"])
        XCTAssertNil(store.findDuplicate(of: store.papers["d"]), "a deck and its paper aren't duplicates")

        store.selectSidebar(.slides)
        XCTAssertEqual(store.view, .slides)
        XCTAssertEqual(store.sidebarSelection, .slides)
        XCTAssertEqual(store.filteredPapers().map(\.id), ["d"])
        XCTAssertEqual(store.sidebarCount(.slides), 1)
        XCTAssertFalse(store.showsNoSlides)
        XCTAssertEqual(LibraryPresentation.title(view: store.view, tag: nil, author: nil), "Slides")
    }

    func testImportSheetStartsAsADeckOverSlides() async {
        let store = await makeStore([])
        XCTAssertTrue(store.sidebarItems.contains(.slides))
        var form = ImportForm()
        _ = store.prepareImport(&form)
        XCTAssertFalse(form.isSlides)
        store.selectSidebar(.slides)
        XCTAssertTrue(store.showsNoSlides)
        XCTAssertEqual(LibraryPresentation.emptyState(libraryIsEmpty: true, search: "", noSlides: store.showsNoSlides), .noSlides)
        form = ImportForm()
        _ = store.prepareImport(&form)
        XCTAssertTrue(form.isSlides)
    }

    func testAskReadsTheSavedSlidesWithoutDescribingAgain() async throws {
        let store = await makeStore([deck("d")])
        try await storage.write(K.pdf("d"), Fixtures.pdf(lines: ["Accuracy over time"]))
        await storage.save(["Slide 1\nAccuracy over time\n[What the slide shows: SAVED CHART]"], K.slides("d"))
        nonisolated(unsafe) var systems: [String] = []
        MockLLM.install { request in
            systems.append(MockLLM.allText(in: request))
            return (200, MockLLM.chatReply("It rises."))
        }
        store.llm.baseUrl = "http://mock.local/v1"
        await store.ask("d", "What does the chart show?")
        XCTAssertEqual(store.chats["d"]?.last?.text, "It rises.")
        XCTAssertEqual(systems.count, 1, "no slide is described again")
        XCTAssertTrue(systems[0].contains(PromptSettings.defaults.slidesSource))
        XCTAssertTrue(systems[0].contains("SAVED CHART"))
    }
}

/// The import sheet's deck toggle.
final class SlidesImportFormTests: PapertalkTestCase {
    func testADeckSkipsTheLibraryChoice() {
        var form = ImportForm()
        form.library = "lib"
        form.setFile(name: "talk.pdf", data: Data("x".utf8))
        XCTAssertTrue(form.showsSlidesToggle)
        XCTAssertTrue(form.showsLibraryChoice)
        XCTAssertEqual(form.submission?.library, "lib")
        XCTAssertEqual(form.submission?.slides, false)

        form.isSlides = true
        XCTAssertFalse(form.showsLibraryChoice)
        XCTAssertNil(form.submission?.library, "decks live only in Slides")
        XCTAssertEqual(form.submission?.slides, true)

        form.rerun(Fixtures.paper(id: "p"))
        XCTAssertFalse(form.showsSlidesToggle, "a rerun stays what it was")
    }
}
