// An opt-in end-to-end import with real Kokoro and a mocked LLM (PAPERTALK_E2E=1).

import Foundation
import XCTest
@testable import Papertalk

/// A whole import through the real pipeline: PDF text, the LLM steps (answered
/// by MockLLM), Kokoro synthesis and the baked library folder. Opt-in, since it
/// runs real Kokoro (slow, needs the model): PAPERTALK_E2E=1, plus the LLM
/// settings from the environment (LLM_BASE_URL, PAPERTALK_MODEL) so no real
/// settings are touched. Meant for Linux: `client/linux-dev/dev.sh e2e`.
@MainActor
final class EndToEndImportTests: PapertalkTestCase {
    private static let paperLines = [
        "Attention Mechanisms in Modern Models",
        "Ada Lovelace, Grace Hopper",
        "Abstract",
        "We study attention, which lets a model weigh every word of its input when producing each output.",
        "1 Introduction",
        "Recurrent networks read text one word at a time and forget distant context.",
        "2 Method",
        "Queries, keys and values are projected from the input and combined with a softmax over similarities.",
        "3 Results",
        "On translation benchmarks attention outperforms a recurrent baseline by a clear margin.",
    ]

    func testImportBakesACompleteEpisode() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPERTALK_E2E"] == "1",
                          "End-to-end import is opt-in: PAPERTALK_E2E=1 (client/linux-dev/dev.sh e2e)")
        installLLM()
        let root = Fixtures.tempDir()
        let storage = LocalStorage(root: root)
        // The startup scan replaces the in-memory library with what's on disk, so
        // an import started before it finishes would vanish. A finished paper on
        // disk shows when the scan is done (as in AppStoreTests.makeStore).
        await storage.save(Fixtures.paper(id: "seed"), K.paper("seed"))
        let store = AppStore(storage: storage)
        XCTAssertFalse(store.llm.baseUrl.isEmpty, "set LLM_BASE_URL for the mocked LLM")
        await waitUntil { store.papers["seed"] != nil }

        store.upload(Fixtures.pdf(lines: Self.paperLines), filename: "paper.pdf", depth: .summary, depthNote: "")
        var castNames: [String] = []
        await waitUntil(timeout: 900) {
            if store.pendingDuplicate != nil { store.resolveDuplicate(true) }
            if let cast = store.pendingCast {
                let form = CastForm(proposals: cast.proposals, authors: cast.authors, authorGenders: cast.authorGenders)
                castNames = form.cast.map(\.name)
                store.resolveCast(form.cast)
            }
            return store.papers.values.contains { $0.id != "seed" && ($0.isDone || $0.isError) }
        }

        let paper = try XCTUnwrap(store.papers.values.first { $0.id != "seed" })
        XCTAssertTrue(paper.isDone, paper.statusError ?? "not finished")
        XCTAssertEqual(paper.displayTitle, "Attention Mechanisms in Modern Models")
        XCTAssertEqual(castNames, ["Jordan", "Ada"])

        let folder = root.appendingPathComponent("papers/\(paper.id)", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(Set(["paper.json", "source.pdf", "transcript.json", "audio.json", "turns"]).isSubset(of: Set(files)))
        let turns = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("turns").path)
        let transcript = try JSONDecoder().decode(Transcript.self,
                                                  from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(turns.count, transcript.segments.flatMap(\.turns).count)
        // Baked like the macOS app's turns: 24 kHz mono 16-bit PCM, with real speech in it.
        let wav = try Data(contentsOf: folder.appendingPathComponent("turns/0.wav"))
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav[wav.startIndex + 24..<wav.startIndex + 28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 24_000)
        XCTAssertGreaterThan(wav.count, 24_000 * 2)   // more than a second of audio
    }

    /// Skip audio at the cast prompt: the script is written with the chosen
    /// names and voices, nothing is voiced, and the summary length is kept for
    /// reruns. Needs no Kokoro, only the mocked LLM.
    func testSkippingAudioWritesOnlyTheScript() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPERTALK_E2E"] == "1",
                          "End-to-end import is opt-in: PAPERTALK_E2E=1 (client/linux-dev/dev.sh e2e)")
        installLLM()
        let root = Fixtures.tempDir()
        let storage = LocalStorage(root: root)
        await storage.save(Fixtures.paper(id: "seed"), K.paper("seed"))
        let fake = FakeSpeechBackend()
        let store = AppStore(storage: storage, speech: fake)
        XCTAssertFalse(store.llm.baseUrl.isEmpty, "set LLM_BASE_URL for the mocked LLM")
        await waitUntil { store.papers["seed"] != nil }

        store.upload(Fixtures.pdf(lines: Self.paperLines), filename: "paper.pdf", depth: .summary, depthNote: "",
                     targetMinutes: 10)
        var cast: [SpeakerConfig] = []
        await waitUntil(timeout: 60) {
            if store.pendingDuplicate != nil { store.resolveDuplicate(true) }
            if let prompt = store.pendingCast {
                cast = CastForm(proposals: prompt.proposals, authors: prompt.authors,
                                authorGenders: prompt.authorGenders).cast
                store.resolveCast(cast, voiceAudio: false)
            }
            return store.papers.values.contains { $0.id != "seed" && ($0.isDone || $0.isError) }
        }

        let paper = try XCTUnwrap(store.papers.values.first { $0.id != "seed" })
        XCTAssertTrue(paper.isDone, paper.statusError ?? "not finished")
        XCTAssertTrue(paper.hasScript)
        XCTAssertFalse(paper.hasAudio)
        XCTAssertTrue(fake.calls.isEmpty)
        let onDisk = await storage.exists(Paper.self, K.paper(paper.id))
        let saved = try XCTUnwrap(onDisk)
        XCTAssertEqual(saved.targetMinutes, 10)
        XCTAssertEqual(saved.speakers, cast)
        XCTAssertFalse(saved.hasAudio)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("papers/\(paper.id)").path)
        XCTAssertTrue(files.contains("transcript.json"))
        XCTAssertFalse(files.contains("turns"))
        // The mind map is drawn even without audio.
        XCTAssertTrue(files.contains("mindmap.json"))
        XCTAssertEqual(saved.hasMindMap, true)
    }

    /// Canned replies for each pipeline prompt, matched like the other pipeline tests.
    private func installLLM() {
        let meta = #"{"title":"Attention Mechanisms in Modern Models","authors":["Ada Lovelace","Grace Hopper"],"affiliations":["UCL"],"doi":"","tags":["nlp"]}"#
        let cast = #"{"speakers":[{"role":"Interviewer","gender":"male","name":"Jordan"},{"role":"Scientist","gender":"female","name":"Ada"}],"authors":[{"name":"Ada Lovelace","gender":"female"},{"name":"Grace Hopper","gender":"female"}]}"#
        let outline = #"{"tags":["nlp"],"sections":[{"title":"Abstract","min_sec":20},{"title":"Method","min_sec":20}],"segments":[{"title":"Abstract","goal":"overview","sections":[1],"key_points":["survey"],"weight":0.5,"monologue":false},{"title":"Method","goal":"how","sections":[2],"key_points":["attention"],"weight":0.5,"monologue":false}]}"#
        let dialogue = """
        Jordan: Welcome to Papertalk.
        Ada: Thanks. This paper looks at how attention lets a model focus on the right words.
        Jordan: What did the authors actually measure?
        Ada: They compared it with a recurrent baseline and saw clear gains in translation quality.
        """
        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            if request.url?.path.hasSuffix("/models") == true { return (200, MockLLM.modelsReply(["m"])) }
            if text.contains("bibliographic metadata") { return (200, MockLLM.chatReply(meta)) }
            if text.contains("You are casting") { return (200, MockLLM.chatReply(cast)) }
            if text.contains("mappa mentale") { return (200, MockLLM.chatReply(MindMapFixtures.reply())) }
            if text.contains(#""segments": [{"title""#) || text.contains(#""sections": [{"title""#) {
                return (200, MockLLM.chatReply(outline))
            }
            if text.contains("SEGMENT") { return (200, MockLLM.chatReply(dialogue)) }
            return (200, MockLLM.chatReply("{}"))
        }
    }
}
