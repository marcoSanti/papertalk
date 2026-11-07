// Tests of Ask: the chat's context and wording (`PaperChat`), the LLM call
// (`LocalPipeline.ask`) and the store's chat state (`AppStore.ask`, `clearChat`).

import Foundation
import XCTest
@testable import Papertalk

/// The context bundle and the composer's rules.
final class PaperChatPresentationTests: PapertalkTestCase {
    func testContextHasTheStoredDetailsThenTheText() {
        var p = Fixtures.paper(title: "Attention", tags: ["nlp"], authors: ["Ada Lovelace", "Alan Turing"], doi: "10.1/x")
        p.affiliations = ["Cambridge"]
        let c = PaperChat.context(for: p, text: "  Abstract. We study attention.\n")
        XCTAssertTrue(c.hasPrefix("PAPER DETAILS\nTitle: Attention\nAuthors: Ada Lovelace, Alan Turing\nAffiliations: Cambridge\nDOI: 10.1/x\nTopics: nlp"))
        XCTAssertTrue(c.hasSuffix("PAPER TEXT\nAbstract. We study attention."))
        XCTAssertFalse(c.contains("Published:"), "empty fields are left out")
    }

    func testContextCutsLongText() {
        let c = PaperChat.context(for: Fixtures.paper(), text: String(repeating: "a", count: PaperChat.maxTextCharacters + 10))
        XCTAssertTrue(c.hasSuffix(String(repeating: "a", count: 5) + "\n[The text is cut here.]"))
        XCTAssertFalse(c.contains(String(repeating: "a", count: PaperChat.maxTextCharacters + 1)))
    }

    func testQuestionAndSend() {
        XCTAssertEqual(PaperChat.question("  why?\n"), "why?")
        XCTAssertNil(PaperChat.question(" \n "))
        XCTAssertTrue(PaperChat.canSend("why?", answering: false))
        XCTAssertFalse(PaperChat.canSend("why?", answering: true))
        XCTAssertFalse(PaperChat.canSend("  ", answering: false))
    }

    func testHistoryLeavesOutFailedAnswers() {
        let msgs = [ChatMessage(role: .user, text: "a"), .failure("HTTP 500"), ChatMessage(role: .user, text: "b")]
        XCTAssertEqual(PaperChat.history(msgs).map(\.text), ["a", "b"])
    }

    func testWording() {
        XCTAssertEqual(PaperChat.windowTitle(Fixtures.paper(title: "Attention")), "Ask — Attention")
        XCTAssertEqual(PaperChat.suggestions.count, 4)
        XCTAssertFalse(PaperChat.placeholder.isEmpty || PaperChat.emptyTitle.isEmpty || PaperChat.emptyHint.isEmpty
                       || PaperChat.sendHelp.isEmpty || PaperChat.clearTitle.isEmpty || PaperChat.thinking.isEmpty)
    }

    func testPagedTextMarksEachPage() {
        XCTAssertEqual(PaperChat.pagedText(["One.", "Two."]), "[Page 1]\nOne.\n[Page 2]\nTwo.")
    }

    func testCitationsBecomeLinksThatReadBack() throws {
        let text = PaperChat.linkingCitations(#"It wins [[p. 3: "beats the baseline (by 2%)"]] and “p” [[Page 12: “we use attention”]]."#)
        XCTAssertTrue(text.hasPrefix("It wins [p. 3](papertalk-source:3?"))
        XCTAssertTrue(text.contains("[p. 12](papertalk-source:12?"))
        XCTAssertEqual(PaperChat.linkingCitations("no [[cites]] here"), "no [[cites]] here")
        let accented = PaperChat.formatted(PaperChat.linkingCitations(#"x [[p. 2: "café señal über"]]"#)).runs.compactMap(\.link)
        XCTAssertEqual(accented.compactMap(PaperChat.citation(from:)), [.init(page: 2, quote: "café señal über")],
                       "accented quotes still make a link")

        let links = PaperChat.formatted(text).runs.compactMap(\.link)
        XCTAssertEqual(links.compactMap(PaperChat.citation(from:)),
                       [.init(page: 3, quote: "beats the baseline (by 2%)"), .init(page: 12, quote: "we use attention")])
        XCTAssertNil(PaperChat.citation(from: try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertNil(PaperChat.citation(from: try XCTUnwrap(URL(string: "papertalk-source:0?x"))))
    }

    func testCitationsInAnAnswer() {
        XCTAssertEqual(PaperChat.citations(in: #"A [[p. 2: "one two"]] b [[p. 5: "three"]]"#),
                       [.init(page: 2, quote: "one two"), .init(page: 5, quote: "three")])
        XCTAssertEqual(PaperChat.citations(in: "none"), [])
    }

    func testLocateIgnoresWhatPDFTextAndQuotesDisagreeOn() {
        let page = "We pro-\npose a new ﬁlter, called   Café-Net.\nIt works."
        let ns = page as NSString
        let r = PaperChat.locate("we propose a new filter called cafe net", in: page)
        XCTAssertEqual(r.map { ns.substring(with: $0) }, "We pro-\npose a new ﬁlter, called   Café-Net")
        XCTAssertEqual(PaperChat.locate("“It works.”", in: page).map { ns.substring(with: $0) }, "It works")
        XCTAssertNil(PaperChat.locate("it fails", in: page))
        XCTAssertNil(PaperChat.locate("  ,, ", in: page))
        XCTAssertNil(PaperChat.locate("much longer than the page text itself, by far", in: "short"))
    }

    func testSearchStringsTryTheWholeQuoteThenItsStart() {
        XCTAssertEqual(PaperChat.searchStrings("a b c d e f g h i j"),
                       ["a b c d e f g h i j", "a b c d e f g h", "a b c d e", "a b c"])
        XCTAssertEqual(PaperChat.searchStrings(" a\n b "), ["a b"])
        XCTAssertEqual(PaperChat.searchStrings(""), [])
    }

    func testSourceWording() {
        XCTAssertEqual(PaperChat.sourceTitle(page: 4), "Page 4")
        XCTAssertEqual(PaperChat.sourceTitle(page: nil), "The paper")
        XCTAssertNil(PaperChat.sourceNote(highlights: nil))
        XCTAssertNil(PaperChat.sourceNote(highlights: [.zero]))
        XCTAssertEqual(PaperChat.sourceNote(highlights: []), PaperChat.sourceNotFound)
        XCTAssertFalse(PaperChat.sourceLoading.isEmpty)
    }

    func testPagesAreExtractedOneByOne() {
        let pages = LocalPipeline.extractPages(Fixtures.pdf(lines: ["Hello world"]))
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("Hello world"))
        XCTAssertEqual(LocalPipeline.extractPages(Data("nope".utf8)), [])
    }

    #if os(macOS)
    func testFormattedRendersMarkdown() {
        let s = PaperChat.formatted("a **bold** b")
        XCTAssertEqual(String(s.characters), "a bold b")
        XCTAssertEqual(String(PaperChat.formatted("[unclosed").characters), "[unclosed")
    }

    @MainActor
    func testAnswerTextShowsCitationsAsIconLinks() async throws {
        let s = AnswerText.attributed(#"It is **fast** [[p. 4: "runs in the kernel"]] and `code`."#)
        let ns = s.string as NSString
        let bold = try XCTUnwrap(s.attribute(.font, at: ns.range(of: "fast").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let code = try XCTUnwrap(s.attribute(.font, at: ns.range(of: "code").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(code.isFixedPitch)

        let label = ns.range(of: "p. 4")
        XCTAssertNotEqual(label.location, NSNotFound)
        let iconAt = label.location - 2   // the icon, then a no-break space
        XCTAssertNotNil(s.attribute(.attachment, at: iconAt, effectiveRange: nil), "a page icon leads the label")
        let links = [iconAt, label.location].map { s.attribute(.link, at: $0, effectiveRange: nil) as? URL }
        XCTAssertEqual(links.map { $0.flatMap(PaperChat.citation(from:)) }, Array(repeating: .init(page: 4, quote: "runs in the kernel"), count: 2),
                       "the icon and the label are one link to the citation")
        XCTAssertNil(s.attribute(.link, at: ns.range(of: "fast").location, effectiveRange: nil))
    }

    @MainActor
    func testAnswerTextMeasuresEveryWrappedLine() async {
        let s = AnswerText.attributed(String(repeating: "A long answer that wraps. ", count: 40) + "\n\nSecond paragraph.")
        let wide = AnswerText.measure(s, width: 2000), narrow = AnswerText.measure(s, width: 300)
        XCTAssertLessThanOrEqual(narrow.width, 300)
        XCTAssertGreaterThan(narrow.height, wide.height * 3, "narrower wraps into more lines, all counted")
        let line = NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height
        XCTAssertGreaterThan(wide.height, line * 2.5, "every paragraph is counted, not just the first")
        XCTAssertEqual(AnswerText.measure(AnswerText.attributed("hi"), width: 500).width,
                       AnswerText.measure(AnswerText.attributed("hi"), width: 900).width, "a short answer hugs its text")
    }

    func testFindLocatesTheQuoteNearItsPage() throws {
        let pdf = Fixtures.pdf(lines: ["Attention is all you need", "second line here"])
        let hit = try XCTUnwrap(PDFSource.find(.init(page: 1, quote: "Second line, here"), in: pdf))
        XCTAssertEqual(hit.page, 1)
        XCTAssertEqual(hit.rects.count, 1)
        // Line 2's baseline is at y 724 of 792, measured from the bottom: near the top of the page.
        XCTAssertEqual(hit.rects[0].midY, 1 - 728.0 / 792, accuracy: 0.03)
        XCTAssertEqual(hit.rects[0].minX, 72.0 / 612, accuracy: 0.02)
        XCTAssertEqual(PDFSource.find(.init(page: 2, quote: "second line here"), in: pdf)?.page, 1,
                       "a page miscounted by one is still found")
        XCTAssertNotNil(PDFSource.find(.init(page: 1, quote: "second line here and then made up words"), in: pdf),
                        "a misquoted end still finds the opening words")
        XCTAssertNil(PDFSource.find(.init(page: 1, quote: "not on the page"), in: pdf))
        XCTAssertEqual(PDFSource.find(.init(page: 9, quote: "second line here"), in: pdf)?.page, 1,
                       "a wrong page falls back to the rest of the paper")
    }
    #endif
}

/// `LocalPipeline.ask` sends the prompt and context as the system message, then the chat.
final class PaperChatPipelineTests: PapertalkTestCase {
    override func tearDown() {
        MockLLM.uninstall()
        super.tearDown()
    }

    func testAskSendsContextAndHistory() async throws {
        nonisolated(unsafe) var sent: [[String: Any]] = []
        MockLLM.install { request in
            let obj = try? JSONSerialization.jsonObject(with: MockLLM.bodyData(request) ?? Data()) as? [String: Any]
            sent = obj?["messages"] as? [[String: Any]] ?? []
            return (200, MockLLM.chatReply("  It uses attention.\n"))
        }
        let history = [ChatMessage(role: .user, text: "What is it?"), ChatMessage(role: .assistant, text: "A model."),
                       ChatMessage(role: .user, text: "How?")]
        let reply = try await LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "", model: "m")
            .ask(context: "PAPER TEXT\nhello", history: history)
        XCTAssertEqual(reply, "It uses attention.")
        XCTAssertEqual(sent.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        let system = sent.first?["content"] as? String ?? ""
        XCTAssertTrue(system.hasPrefix(PromptSettings.defaults.ask))
        XCTAssertTrue(system.contains(PaperChat.citationRule), "the citation format is added whatever the prompt says")
        XCTAssertTrue(system.hasSuffix("PAPER TEXT\nhello"))
        XCTAssertEqual(sent.last?["content"] as? String, "How?")
    }
}

/// The store keeps each paper's chat and reports why a question can't be answered.
@MainActor
final class PaperChatStoreTests: PapertalkTestCase {
    func testAskWithoutAPDFSaysWhy() async {
        let storage = LocalStorage(root: Fixtures.tempDir())
        let p = Fixtures.paper(id: "p")
        await storage.save(p, K.paper(p.id))
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == 1 }

        await store.ask("p", "   ")
        XCTAssertNil(store.chats["p"], "an empty question is ignored")

        await store.ask("p", " What is it? ")
        let chat = store.chats["p"] ?? []
        XCTAssertEqual(chat.map(\.text), ["What is it?", "This paper has no PDF to read."])
        XCTAssertEqual(chat.map(\.isError), [false, true])
        XCTAssertFalse(store.answering.contains("p"))

        store.clearChat("p")
        XCTAssertNil(store.chats["p"])
    }
}
