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

    #if os(macOS)
    func testFormattedRendersMarkdown() {
        let s = PaperChat.formatted("a **bold** b")
        XCTAssertEqual(String(s.characters), "a bold b")
        XCTAssertEqual(String(PaperChat.formatted("[unclosed").characters), "[unclosed")
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
