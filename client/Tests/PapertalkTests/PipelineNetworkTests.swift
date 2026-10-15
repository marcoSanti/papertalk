import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk

/// Exercises `LocalPipeline`'s public entry points against a fully-mocked LLM
/// server (MockLLM intercepts URLSession). No network or real model is touched.
final class PipelineNetworkTests: PapertalkTestCase {
    override func tearDown() {
        MockLLM.uninstall()
        super.tearDown()
    }

    /// A pipeline whose mock answers every chat call with `content` when the
    /// request's system+user text contains `needle`, else fails the test.
    func chatPipeline(whenUserContains needle: String, reply: String) -> LocalPipeline {
        let base = "http://mock.local/v1"
        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            if text.contains(needle) {
                return (200, MockLLM.chatReply(reply))
            }
            XCTFail("unexpected prompt for needle '\(needle)': \(text.prefix(80))")
            return (500, Data())
        }
        return LocalPipeline(baseUrl: base, apiKey: "k", model: "m")
    }

    // MARK: listModels

    func testListModels() async throws {
        MockLLM.install { _ in (200, MockLLM.modelsReply(["llama", "mistral", "gpt"])) }
        let ids = try await LocalPipeline(baseUrl: "http://mock.local", apiKey: "", model: "m").listModels()
        XCTAssertEqual(ids, ["llama", "mistral", "gpt"])
    }

    func testListModelsThrowsOnBadBody() async {
        MockLLM.install { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await LocalPipeline(baseUrl: "http://mock.local", apiKey: "", model: "m").listModels()
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    // MARK: extractMeta

    func testExtractMetaParses() async throws {
        let reply = #"{"title":"Real Title","authors":["Ada Lovelace","Grace Hopper"],"affiliations":["UCL"],"doi":"10.1/x","tags":["computing-history"]}"#
        let p = chatPipeline(whenUserContains: "bibliographic metadata", reply: reply)
        let meta = try await p.extractMeta(text: "some paper", fallbackTitle: "Fallback")
        XCTAssertEqual(meta.title, "Real Title")
        XCTAssertEqual(meta.authors, ["Ada Lovelace", "Grace Hopper"])
        XCTAssertEqual(meta.affiliations, ["UCL"])
        XCTAssertEqual(meta.doi, "10.1/x")
        XCTAssertEqual(meta.tags, ["computing-history"])
    }

    func testExtractMetaFallsBackOnUnusableReply() async throws {
        let p = chatPipeline(whenUserContains: "bibliographic metadata", reply: "no json here at all")
        let meta = try await p.extractMeta(text: "some paper", fallbackTitle: "Fallback Title")
        XCTAssertEqual(meta.title, "Fallback Title") // fallback title used
        // The unusable-reply early-return carries no default tag.
        XCTAssertTrue(meta.tags.isEmpty)
        XCTAssertTrue(meta.authors.isEmpty)
    }

    func testExtractMetaSurvivesProseAroundJSON() async throws {
        let reply = "Sure! Here is the metadata: {\"title\":\"T\",\"authors\":[\"A\"],\"affiliations\":[],\"doi\":\"\",\"tags\":[\"nlp\"]}. Done."
        let p = chatPipeline(whenUserContains: "bibliographic metadata", reply: reply)
        let meta = try await p.extractMeta(text: "x", fallbackTitle: "F")
        XCTAssertEqual(meta.title, "T")
        XCTAssertEqual(meta.authors, ["A"])
        XCTAssertEqual(meta.tags, ["nlp"])
    }

    // MARK: proposeCast

    func testProposeCastParsesAndValidatesGenders() async {
        let reply = #"{"speakers":[{"role":"Interviewer","gender":"female","name":"Mia"},{"role":"Scientist","gender":null,"name":"Ada"}],"authors":[{"name":"Ada Lovelace","gender":"female"}]}"#
        let p = chatPipeline(whenUserContains: "You are casting", reply: reply)
        let cast = await p.proposeCast(title: "T", authors: ["Ada Lovelace"], cleaned: "text", depthNote: "")
        XCTAssertEqual(cast.speakers.count, 2)
        XCTAssertEqual(cast.speakers[0].role, "Interviewer")
        XCTAssertEqual(cast.speakers[0].gender, "female")
        // The scientist's missing gender is back-filled from the author list.
        XCTAssertEqual(cast.speakers[1].gender, "female")
        XCTAssertEqual(cast.authorGenders["Ada Lovelace"], "female")
    }

    func testProposeCastFallsBackWhenModelReplyUnusable() async {
        let p = chatPipeline(whenUserContains: "You are casting", reply: "not json")
        let cast = await p.proposeCast(title: "T", authors: ["Ada Lovelace"], cleaned: "text", depthNote: "")
        XCTAssertEqual(cast.speakers.count, 2)
        XCTAssertEqual(cast.speakers[0].role, "Interviewer")
        // Fallback keeps a real scientist guess from the author list, not empty.
        XCTAssertEqual(cast.speakers[1].name, "Ada")
    }

    // MARK: generateTranscript

    private let samplePaper = """
    Attention Mechanisms in Modern Models
    Ada Lovelace, Grace Hopper
    Abstract
    We survey attention.
    Introduction
    Attention matters everywhere.
    Method
    The model attends over the sequence using query, key and value projections.
    Conclusion
    We conclude.
    """

    private func installFullTranscriptMock() {
        let outline = #"{"tags":["nlp"],"sections":[{"title":"Abstract","min_sec":20},{"title":"Introduction","min_sec":20},{"title":"Method","min_sec":20}],"segments":[{"title":"Abstract","goal":"overview","sections":[1],"key_points":["survey"],"weight":0.34,"monologue":false},{"title":"Introduction","goal":"why","sections":[2],"key_points":["context"],"weight":0.33,"monologue":false},{"title":"Method","goal":"how","sections":[3],"key_points":["attention"],"weight":0.33,"monologue":false}]}"#

        MockLLM.install { request in
            let user = MockLLM.allText(in: request)
            if user.contains(#""sections": [{"title""#) || user.contains(#""segments": [{"title""#) {
                MockLLM.note(flag: "outline")
                return (200, MockLLM.chatReply(outline))
            }
            if user.contains("SEGMENT") {
                MockLLM.note(flag: "dialogue")
                return (200, MockLLM.chatReply(dialogReply(jordan: "Jordan", sam: "Ada")))
            }
            XCTFail("unexpected prompt: \(user.prefix(100))")
            return (500, Data())
        }
    }

    func testGenerateTranscriptRunsEndToEndAsDialogue() async throws {
        installFullTranscriptMock()
        var p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        p.log = { _ in }  // silence

        let result = try await p.generateTranscript(text: samplePaper, depth: .summary, depthNote: "")
        XCTAssertEqual(result.transcript.segments.count, 3)
        XCTAssertEqual(result.transcript.speakers.count, 2)
        // Host default "Jordan", expert is the author's first name "Ada".
        XCTAssertEqual(result.transcript.speakers.map(\.name), ["Jordan", "Ada"])
        // Every turn must be spoken by one of the two cast.
        let spk = Set(result.transcript.segments.flatMap { $0.turns }.map { $0.speaker })
        XCTAssertTrue(spk.isSubset(of: ["Jordan", "Ada"]))
        XCTAssertFalse(spk.isEmpty)
        XCTAssertEqual(result.title, "Attention Mechanisms in Modern Models")
        // detectAuthors stops at 3 tokens; the two real authors must lead.
        XCTAssertEqual(Array(result.authors.prefix(2)), ["Ada Lovelace", "Grace Hopper"])
        XCTAssertTrue(MockLLM.seen.contains("outline"))
        XCTAssertTrue(MockLLM.seen.contains("dialogue"))
    }

    func testGenerateTranscriptProducesMonologueForInDepthMethod() async throws {
        // Segment 3 (Method) is monologue: true, an in-depth episode keeps it.
        let outline = #"{"tags":[],"sections":[{"title":"Abstract","min_sec":20},{"title":"Method","min_sec":20}],"segments":[{"title":"Abstract","goal":"g","sections":[1],"key_points":["0"],"weight":0.5,"monologue":false},{"title":"Method","goal":"g","sections":[2],"key_points":["attention"],"weight":0.5,"monologue":true}]}"#

        MockLLM.install { request in
            let user = MockLLM.allText(in: request)
            if user.contains(#""segments": [{"title""#) {
                MockLLM.note(flag: "outline")
                return (200, MockLLM.chatReply(outline))
            }
            if user.contains("METHOD TEXT") {
                MockLLM.note(flag: "monologue")
                return (200, MockLLM.chatReply("The model projects queries, keys and values to attend over the sequence faithfully."))
            }
            if user.contains("SEGMENT") {
                MockLLM.note(flag: "dialogue")
                return (200, MockLLM.chatReply(dialogReply(jordan: "Jordan", sam: "Ada")))
            }
            XCTFail("unexpected prompt: \(user.prefix(100))")
            return (500, Data())
        }

        var p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        p.log = { _ in }
        let result = try await p.generateTranscript(text: samplePaper, depth: .inDepth, depthNote: "")

        // The method segment was written as a single expert narration.
        XCTAssertTrue(MockLLM.seen.contains("monologue"))
        let methodSegment = result.transcript.segments.last!
        XCTAssertTrue(methodSegment.turns.allSatisfy { $0.speaker == "Ada" })
        XCTAssertTrue(methodSegment.turns.contains { $0.text.contains("queries, keys and values") })
    }

    func testGenerateTranscriptForcesDialogueForNonInDepth() async throws {
        // Summary depth: even if the outline marks a segment monologue, it must
        // be rewritten as dialogue (AGENTS.md pipeline rule).
        let outline = #"{"tags":[],"sections":[{"title":"Method","min_sec":20}],"segments":[{"title":"Method","goal":"g","sections":[1],"key_points":["attention"],"weight":1.0,"monologue":true}]}"#

        MockLLM.install { request in
            let user = MockLLM.allText(in: request)
            if user.contains(#""segments": [{"title""#) {
                MockLLM.note(flag: "outline")
                return (200, MockLLM.chatReply(outline))
            }
            if user.contains("SEGMENT") {
                MockLLM.note(flag: "dialogue")
                return (200, MockLLM.chatReply(dialogReply(jordan: "Jordan", sam: "Ada")))
            }
            XCTFail("unexpected prompt: \(user.prefix(100))")
            return (500, Data())
        }

        var p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        p.log = { _ in }
        let result = try await p.generateTranscript(text: samplePaper, depth: .summary, depthNote: "")
        // Only dialogue was requested — no monologue path.
        XCTAssertTrue(MockLLM.seen.contains("dialogue"))
        XCTAssertFalse(MockLLM.seen.contains("monologue"))
        // Both host and expert speak.
        let spk = Set(result.transcript.segments.flatMap { $0.turns }.map { $0.speaker })
        XCTAssertEqual(spk, ["Jordan", "Ada"])
    }
}

private func dialogReply(jordan: String, sam: String) -> String {
    "\(jordan): A friendly opening from the host.\n\(sam): A technical reply from the expert.\n\(jordan): Another question.\n\(sam): The detailed response.\n"
}