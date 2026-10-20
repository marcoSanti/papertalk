import XCTest
@testable import Papertalk

final class PaperModelTests: PapertalkTestCase {
    private func makeJSON(speakers: Bool = true, extra: [String: Any] = [:]) -> [String: Any] {
        var obj: [String: Any] = [
            "id": "abc", "title": "A Paper", "filename": "a.pdf",
            "has_pdf": true, "has_script": true, "has_audio": true,
            "created_iso": "2024-01-01T00:00:00Z", "state": "done",
            "tags": ["nlp"], "favorite": false,
            "authors": ["Ada Lovelace"], "affiliations": ["Uni"], "doi": "10.1/x",
            "read": false, "depth": "summary", "bibtex": "@article{x",
            "progress": 0.5, "duration": 120, "stage": "done", "message": "Done",
        ]
        if speakers { obj["speakers"] = [["name": "Jordan", "voice": "af_heart"]] }
        for (k, v) in extra { obj[k] = v }
        return obj
    }

    private func decode(_ dict: [String: Any]) throws -> Paper {
        try JSONDecoder().decode(Paper.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    func testDecodeFullRecord() throws {
        let p = try decode(makeJSON())
        XCTAssertEqual(p.id, "abc")
        XCTAssertEqual(p.displayTitle, "A Paper")
        XCTAssertTrue(p.isDone)
        XCTAssertEqual(p.speakers.count, 1)
        XCTAssertEqual(p.speakers[0].name, "Jordan")
        XCTAssertEqual(p.statusKind, .done)
    }

    func testDecodeToleratesMissingOptionals() throws {
        // Optionals absent must still decode (regression guard per AGENTS.md):
        // a new field becoming non-optional would break every existing paper.json.
        let p = try decode(makeJSON(speakers: false, extra: ["speakers": NSNull(), "published_iso": ""]))
        XCTAssertEqual(p.storedSpeakers, nil)
        XCTAssertEqual(p.speakers, [])
        XCTAssertNil(p.targetMinutes)
        XCTAssertEqual(p.displayTitle, "A Paper")
    }

    func testMindMapFlagIsOptional() throws {
        XCTAssertNil(try decode(makeJSON()).hasMindMap)                       // records from before mind maps
        let p = try decode(makeJSON(extra: ["has_mind_map": true]))
        XCTAssertEqual(p.hasMindMap, true)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        XCTAssertEqual(raw["has_mind_map"] as? Bool, true)
    }

    func testTargetMinutesIsSavedAsTargetMinutes() throws {
        let p = try decode(makeJSON(extra: ["target_minutes": 20]))
        XCTAssertEqual(p.targetMinutes, 20)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        XCTAssertEqual(raw["target_minutes"] as? Int, 20)
    }

    func testCodableRoundTrip() throws {
        let p = try decode(makeJSON())
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Paper.self, from: data)
        XCTAssertEqual(back, p)
    }

    func testSpeakersWrapperNilsEmpty() {
        var p = Paper(id: "x", title: nil, filename: nil, hasPdf: false, hasScript: false, hasAudio: false,
                      createdIso: nil, publishedIso: nil, state: "draft", tags: [], favorite: false,
                      authors: [], affiliations: [], doi: "", read: false, depth: nil, bibtex: nil,
                      progress: 0, duration: 0, progressTs: nil, stage: nil, message: nil, statusError: nil)
        p.speakers = []
        // Setting an empty array must persist as nil (no "speakers": [] in JSON).
        XCTAssertNil(p.storedSpeakers)
        let data = try! JSONEncoder().encode(p)
        let raw = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(raw["speakers"])

        p.speakers = [SpeakerConfig(name: "A", voice: "af_heart")]
        XCTAssertEqual(p.storedSpeakers?.count, 1)
    }

    func testDisplayTitleFallbacks() {
        var p = try! decode(makeJSON(extra: ["title": "  "]))
        XCTAssertEqual(p.displayTitle, "a.pdf") // nil title -> filename
        p.filename = nil
        XCTAssertEqual(p.displayTitle, "Untitled")
    }

    func testStatusKind() {
        XCTAssertEqual(makePaper(state: "running").statusKind, .running)
        XCTAssertEqual(makePaper(state: "queued").statusKind, .running)
        XCTAssertEqual(makePaper(state: "awaiting_audio").statusKind, .running)
        XCTAssertEqual(makePaper(state: "done").statusKind, .done)
        XCTAssertEqual(makePaper(state: "error").statusKind, .error)
        XCTAssertEqual(makePaper(state: "draft").statusKind, .unknown)
    }

    func testDismissingErrorKeepsScript() {
        var p = makePaper(state: "error", hasScript: true)
        p.progress = 0.4; p.message = "boom"; p.statusError = "boom"
        let next = p.dismissingError()
        XCTAssertEqual(next.state, "done")
        XCTAssertNil(next.statusError)
        XCTAssertEqual(next.progress, 1)
    }

    func testDismissingErrorWithoutScriptBecomesDraft() {
        let p = makePaper(state: "error", hasScript: false)
        let next = p.dismissingError()
        XCTAssertEqual(next.state, "draft")
        XCTAssertNil(next.stage)
        XCTAssertNil(next.statusError)
        XCTAssertEqual(next.progress, 0)
    }

    func testDepthTitle() {
        var p = try! decode(makeJSON())
        XCTAssertEqual(p.depthTitle, "Summary")
        p.depth = "nonsense"
        XCTAssertNil(p.depthTitle)
        p.depth = nil
        XCTAssertNil(p.depthTitle)
    }

    private func makePaper(state: String, hasScript: Bool = false) -> Paper {
        Paper(id: "x", title: nil, filename: nil, hasPdf: false, hasScript: hasScript, hasAudio: false,
              createdIso: nil, publishedIso: nil, state: state, tags: [], favorite: false,
              authors: [], affiliations: [], doi: "", read: false, depth: nil, bibtex: nil,
              progress: 0, duration: 0, progressTs: nil, stage: nil, message: nil, statusError: nil)
    }
}

final class TranscriptModelTests: PapertalkTestCase {
    func testRoundTrip() throws {
        let t = Transcript(paperTitle: "P",
                           speakers: [.init(name: "Host")],
                           segments: [.init(title: "S", turns: [.init(speaker: "Host", text: "hi")])])
        let back = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.paperTitle, "P")
        XCTAssertEqual(back.speakers.count, 1)
        XCTAssertEqual(back.segments[0].turns[0].text, "hi")
    }

    func testDecodeToleratesMissingKeys() throws {
        let back = try JSONDecoder().decode(Transcript.self, from: #"{}"#.data(using: .utf8)!)
        XCTAssertNil(back.paperTitle)
        XCTAssertTrue(back.speakers.isEmpty)
        XCTAssertTrue(back.segments.isEmpty)
    }

    func testPaperTitleCodingKey() throws {
        let json = #"{"paper_title":"Real","speakers":[],"segments":[]}"#
        let t = try JSONDecoder().decode(Transcript.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(t.paperTitle, "Real")
    }
}

final class AudioManifestTests: PapertalkTestCase {
    func testRoundTrip() throws {
        let m = AudioManifest(durations: [1.5, 2.0])
        let back = try JSONDecoder().decode(AudioManifest.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.durations, [1.5, 2.0])
    }
}

final class ServerKeyLayoutTests: PapertalkTestCase {
    func testKeys() {
        XCTAssertEqual(K.folder("abc"), "papers/abc/")
        XCTAssertEqual(K.paper("abc"), "papers/abc/paper.json")
        XCTAssertEqual(K.transcript("abc"), "papers/abc/transcript.json")
        XCTAssertEqual(K.audioManifest("abc"), "papers/abc/audio.json")
        XCTAssertEqual(K.turn("abc", 3), "papers/abc/turns/3.wav")
        XCTAssertEqual(K.pdf("abc"), "papers/abc/source.pdf")
    }
}