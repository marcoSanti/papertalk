import XCTest
@testable import Papertalk

/// Tests for the formatting/parsing helpers in the pipeline that carry no I/O.
final class PipelineParserTests: PapertalkTestCase {

    // MARK: Parsers.dialogue

    func testDialogueParsesTurns() {
        let raw = """
        Jordan: Hello and welcome.
        Sam: Thanks for having me.

        Jordan: Tell us about the method.
        Sam: Sure thing.
        """
        let turns = Parsers.dialogue(from: raw, names: ["Jordan", "Sam"])
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(turns[0].speaker, "Jordan")
        XCTAssertEqual(turns[1].speaker, "Sam")
        XCTAssertEqual(turns[1].text, "Thanks for having me.")
    }

    func testDialogueNormalizesSpeakerCaseAndPrefix() {
        let raw = "JORDAN: hi\nsammuel: bye\n"
        let turns = Parsers.dialogue(from: raw, names: ["Jordan", "Sam"])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speaker, "Jordan")
        XCTAssertEqual(turns[1].speaker, "Sam") // matches "Sam" prefix of "sammuel"
    }

    func testDialogueSkipsUnknownSpeakersAndMalformedLines() {
        let raw = """
        Narrator: ignore me
        NoColonHere
        Jordan: 
        : only-colon
        Jordan: good
        """
        let turns = Parsers.dialogue(from: raw, names: ["Jordan", "Sam"])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "good")
    }

    func testDialogueEmptyInput() {
        XCTAssertTrue(Parsers.dialogue(from: "", names: ["Jordan", "Sam"]).isEmpty)
        XCTAssertTrue(Parsers.dialogue(from: "\n\n\n", names: ["Jordan", "Sam"]).isEmpty)
    }

    // MARK: readThroughTurns

    func testReadThroughChunksOverCap() {
        // Two long lines pushed past the 1400-char cap become separate turns.
        let long = String(repeating: "a", count: 1500)
        let text = long + "\n" + "bb"
        let turns = LocalPipeline.readThroughTurns(text)
        XCTAssertGreaterThan(turns.count, 1)
        XCTAssertEqual(turns.first?.speaker, "Reader")
        XCTAssertTrue(turns.allSatisfy { $0.speaker == "Reader" })
    }

    func testReadThroughCombinesShortLines() {
        let turns = LocalPipeline.readThroughTurns("one line\nanother line\n")
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns[0].text.contains("one line"))
        XCTAssertTrue(turns[0].text.contains("another line"))
    }

    func testReadThroughDropsBlankAndSingleChars() {
        let turns = LocalPipeline.readThroughTurns("hello\n\n\nx\nworld\n")
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "hello world")
    }

    // MARK: AppStore.matches

    @MainActor
    func testStatusMatchesRunningCoversActiveStates() {
        func paper(_ state: String) -> Paper {
            Paper(id: "x", title: nil, filename: nil, hasPdf: false, hasScript: false, hasAudio: false,
                  createdIso: nil, publishedIso: nil, state: state, tags: [], favorite: false,
                  authors: [], affiliations: [], doi: "", read: false, depth: nil, bibtex: nil,
                  progress: 0, duration: 0, progressTs: nil, stage: nil, message: nil, statusError: nil)
        }
        XCTAssertTrue(AppStore.matches(paper("running"), status: "running"))
        XCTAssertTrue(AppStore.matches(paper("queued"), status: "running"))
        XCTAssertTrue(AppStore.matches(paper("awaiting_audio"), status: "running"))
        XCTAssertFalse(AppStore.matches(paper("done"), status: "running"))
        XCTAssertTrue(AppStore.matches(paper("error"), status: "error"))
    }
}