// Regression tests for the pipeline rules in AGENTS.md.

import XCTest
@testable import Papertalk

/// Regression tests for the pipeline rules in AGENTS.md, run against the mock
/// LLM (`MockLLM`). Each one pins down a bug that has already shipped once.
final class PipelineRuleTests: PapertalkTestCase {
    /// Thread-safe sink for values captured inside the mock or the log closure.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ v: T) { lock.withLock { items.append(v) } }
        var all: [T] { lock.withLock { items } }
    }

    private let paper = """
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

    private func outline(segments: Int, monologueLast: Bool = false, lastSections: String = "[1]") -> String {
        let segs = (0..<segments).map { i -> String in
            let mono = monologueLast && i == segments - 1
            let sections = i == segments - 1 ? lastSections : "[1]"
            return #"{"title":"Seg \#(i)","goal":"g","sections":\#(sections),"key_points":["k"],"weight":1,"monologue":\#(mono)}"#
        }
        return #"{"tags":[],"sections":[{"title":"Abstract","min_sec":20},{"title":"Method","min_sec":20}],"segments":[\#(segs.joined(separator: ","))]}"#
    }

    private func dialogue(words: Int) -> String {
        let body = Array(repeating: "word", count: max(1, words / 2)).joined(separator: " ")
        return "Jordan: \(body)\nAda: \(body)\n"
    }

    private func isOutline(_ text: String) -> Bool { text.contains(#""segments": [{"title""#) }

    private func pipeline(log: Box<String>? = nil) -> LocalPipeline {
        var p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        p.log = { line in log?.append(line) }
        return p
    }

    private func targets(in prompts: [String]) -> [Int] {
        prompts.compactMap { text in
            guard let r = text.range(of: #"TARGET LENGTH: about (\d+) words"#, options: .regularExpression) else { return nil }
            return Int(text[r].filter(\.isNumber))
        }
    }

    // MARK: episode length

    func testSummaryStaysUnderTheThirtyFiveMinuteCeiling() async throws {
        let prompts = Box<String>()
        let plan = outline(segments: 3)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            if isOutline(text) { return (200, MockLLM.chatReply(plan)) }
            prompts.append(text)
            // The model overshoots badly: 4,000 words for every segment.
            return (200, MockLLM.chatReply(dialogue(words: 4000)))
        }
        let result = try await pipeline().generateTranscript(text: paper, depth: .summary)

        // Planned 30 min (4,350 words) split three ways. Each 4,000-word reply
        // is condensed (the mock won't) and then cut to its target, so later
        // segments keep their share and the script stays under the 35-minute
        // ceiling (5,075 words) — it used to come out at 12,000.
        XCTAssertEqual(targets(in: prompts.all), [1450, 1450, 1450])
        XCTAssertEqual(prompts.all.filter { $0.contains("too long for the episode") }.count, 3)
        XCTAssertLessThanOrEqual(LocalPipeline.wordCount(result.transcript.segments.flatMap(\.turns)), 5075)
    }

    func testSummaryPlansThirtyMinutes() async throws {
        let log = Box<String>()
        let plan = outline(segments: 2)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            return (200, MockLLM.chatReply(isOutline(text) ? plan : dialogue(words: 50)))
        }
        _ = try await pipeline(log: log).generateTranscript(text: paper, depth: .summary)
        XCTAssertTrue(log.all.contains { $0.contains("(~30 min, 4350 words)") }, "\(log.all)")
    }

    func testSummaryLengthFollowsTheChosenMinutes() async throws {
        let log = Box<String>()
        let plan = outline(segments: 2)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            return (200, MockLLM.chatReply(isOutline(text) ? plan : dialogue(words: 50)))
        }
        // 10 minutes up top: plan 6/7 of it (~8.6 min, 1,242 words).
        _ = try await pipeline(log: log).generateTranscript(text: paper, depth: .summary, summaryMinutes: 10)
        XCTAssertTrue(log.all.contains { $0.contains("(~9 min, 1242 words)") }, "\(log.all)")
        // Only summaries have a length: in-depth ignores it.
        _ = try await pipeline(log: log).generateTranscript(text: paper, depth: .inDepth, summaryMinutes: 10)
        XCTAssertTrue(log.all.contains { $0.contains("(~30 min, 4350 words)") }, "\(log.all)")
    }

    func testShortSummaryStaysUnderItsCeiling() async throws {
        let prompts = Box<String>()
        let plan = outline(segments: 3)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            if isOutline(text) { return (200, MockLLM.chatReply(plan)) }
            prompts.append(text)
            return (200, MockLLM.chatReply(dialogue(words: 4000)))
        }
        let result = try await pipeline().generateTranscript(text: paper, depth: .summary, summaryMinutes: 5)
        // 5 minutes = 725 words: the 250-word segment floor gives way to the
        // ceiling's share, each segment is told its limit, and the overshoot is cut.
        XCTAssertEqual(targets(in: prompts.all), [241, 242, 242])
        XCTAssertTrue(prompts.all.contains { $0.contains("HARD LIMIT: at most 241 words") })
        XCTAssertLessThanOrEqual(LocalPipeline.wordCount(result.transcript.segments.flatMap(\.turns)), 725)
    }

    func testCondensedSegmentIsKeptWhenItFits() async throws {
        let plan = outline(segments: 1)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            if isOutline(text) { return (200, MockLLM.chatReply(plan)) }
            return (200, MockLLM.chatReply(dialogue(words: text.contains("too long for the episode") ? 300 : 3000)))
        }
        let result = try await pipeline().generateTranscript(text: paper, depth: .summary, summaryMinutes: 5)
        XCTAssertEqual(LocalPipeline.wordCount(result.transcript.segments.flatMap(\.turns)), 300)
    }

    func testInDepthIsNeverCondensed() async throws {
        let prompts = Box<String>()
        let plan = outline(segments: 2)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            if isOutline(text) { return (200, MockLLM.chatReply(plan)) }
            prompts.append(text)
            return (200, MockLLM.chatReply(dialogue(words: 9000)))
        }
        _ = try await pipeline().generateTranscript(text: paper, depth: .inDepth)
        XCTAssertFalse(prompts.all.contains { $0.contains("too long for the episode") || $0.contains("HARD LIMIT") })
    }

    func testTrimTurnsKeepsWholeSentencesAndTheEnding() {
        typealias T = Transcript.Turn
        let turns = [T(speaker: "Jo", text: "One two three. Four five six."),
                     T(speaker: "Ada", text: "Seven eight nine ten. Eleven twelve."),
                     T(speaker: "Jo", text: "Thanks, Ada.")]
        XCTAssertEqual(LocalPipeline.trimTurns(turns, toWords: 100).map(\.text), turns.map(\.text))   // fits: unchanged
        let cut = LocalPipeline.trimTurns(turns, toWords: 9)
        XCTAssertEqual(cut.map(\.text), ["One two three. Four five six.", "Thanks, Ada."])
        XCTAssertLessThanOrEqual(LocalPipeline.wordCount(cut), 9)
        // No sentence fits: the first turn is cut by words.
        let long = [T(speaker: "Jo", text: Array(repeating: "w", count: 50).joined(separator: " "))]
        XCTAssertEqual(LocalPipeline.wordCount(LocalPipeline.trimTurns(long, toWords: 10)), 10)
    }

    // MARK: editable prompts

    func testEditedPromptsAreWhatTheLLMGets() async throws {
        let sent = Box<String>()
        let plan = outline(segments: 2)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            sent.append(text)
            if text.contains("CAST-X") {
                return (200, MockLLM.chatReply(#"{"speakers":[{"role":"Interviewer","gender":"male","name":"Jo"}],"authors":[]}"#))
            }
            return (200, MockLLM.chatReply(isOutline(text) ? plan : dialogue(words: 50)))
        }
        var p = pipeline()
        p.prompts.metadata = "META-X"
        p.prompts.cast = "CAST-X"
        p.prompts.outlineSystem = "EDITOR-X"
        p.prompts.depthSummary = "SUMMARY-X"
        p.prompts.outlineRules = "RULES {depthGuide} {minutes}"
        p.prompts.segmentRequest = "WRITE {segmentNumber}/{segmentCount} IN {targetWords} AS {position}"
        p.prompts.positionFirst = "OPEN-{host}"
        _ = try await p.extractMeta(text: paper, fallbackTitle: "F")
        _ = await p.proposeCast(title: "T", authors: [], cleaned: paper, depthNote: "")
        _ = try await p.generateTranscript(text: paper, depth: .summary, summaryMinutes: 10, host: "Jo", expert: "Ada")

        let all = sent.all
        // The reply formats are still appended after the user's wording.
        XCTAssertTrue(all.contains { $0.contains("META-X") && $0.contains(#""doi": string"#) })
        XCTAssertTrue(all.contains { $0.contains("CAST-X") && $0.contains(#""speakers": [{"role""#) })
        XCTAssertTrue(all.contains { $0.contains("EDITOR-X") && $0.contains("RULES SUMMARY-X 9") && isOutline($0) })
        XCTAssertTrue(all.contains { $0.contains("WRITE 1/2 IN") && $0.contains("AS OPEN-Jo") && $0.contains("Jo: ...") })
    }

    func testInDepthScalesWithThePaperAndHasNoCeiling() async throws {
        let log = Box<String>()
        let plan = outline(segments: 2)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            return (200, MockLLM.chatReply(isOutline(text) ? plan : dialogue(words: 50)))
        }
        // 20,033 words of source → 0.7 × that ≈ 14,023 planned words (~97 min), far past 35.
        let long = paper + "\n" + Array(repeating: "lorem", count: 20_000).joined(separator: " ")
        _ = try await pipeline(log: log).generateTranscript(text: long, depth: .inDepth)
        XCTAssertTrue(log.all.contains { $0.contains("(~97 min, 14023 words)") }, "\(log.all)")
    }

    func testShortInDepthPaperStillGetsAboutThirtyMinutes() async throws {
        let log = Box<String>()
        let plan = outline(segments: 2)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            return (200, MockLLM.chatReply(isOutline(text) ? plan : dialogue(words: 50)))
        }
        _ = try await pipeline(log: log).generateTranscript(text: paper, depth: .inDepth)
        XCTAssertTrue(log.all.contains { $0.contains("(~30 min, 4350 words)") }, "\(log.all)")
    }

    // MARK: monologues

    func testUnmatchedMethodSectionsNeverReadOutTheWholePaper() async throws {
        let calls = Box<String>()
        let log = Box<String>()
        // The monologue segment points at section 2, titled "Method" in the
        // outline, but give it a title the text doesn't contain.
        let plan = outline(segments: 2, monologueLast: true, lastSections: "[2]")
            .replacingOccurrences(of: #""title":"Method""#, with: #""title":"Nonexistent Chapter""#)
        MockLLM.install { [self] request in
            let text = MockLLM.allText(in: request)
            if isOutline(text) { return (200, MockLLM.chatReply(plan)) }
            calls.append(text.contains("METHOD TEXT") ? "monologue" : "dialogue")
            return (200, MockLLM.chatReply(dialogue(words: 50)))
        }
        _ = try await pipeline(log: log).generateTranscript(text: paper, depth: .inDepth)
        XCTAssertFalse(calls.all.contains("monologue"))
        XCTAssertTrue(log.all.contains { $0.contains("method sections not found") })
    }

    // MARK: cast

    func testCastPromptAsksForAJSONObject() async {
        let prompt = Box<String>()
        MockLLM.install { request in
            prompt.append(MockLLM.allText(in: request))
            return (200, MockLLM.chatReply("{}"))
        }
        _ = await pipeline().proposeCast(title: "T", authors: ["Ada Lovelace"], cleaned: "x", depthNote: "")
        // `extractJSON` only handles {...}; a bare-array schema got mangled for weeks.
        XCTAssertTrue(prompt.all.first?.contains(#"{"speakers": ["#) == true)
    }

    func testCastAcceptsLegacyArrayRepliesAndShortGenderWords() async {
        MockLLM.install { _ in
            (200, MockLLM.chatReply(#"[{"role":"Interviewer","gender":"woman","name":"Mia"},{"role":"Scientist","gender":"M","name":"William"}]"#))
        }
        let cast = await pipeline().proposeCast(title: "T", authors: ["William Smith"], cleaned: "x", depthNote: "")
        XCTAssertEqual(cast.speakers.map(\.name), ["Mia", "William"])
        XCTAssertEqual(cast.speakers.map(\.gender), ["female", "male"])
    }

    func testFallbackCastGuessesGenderFromTheName() async {
        MockLLM.install { _ in (200, MockLLM.chatReply("I can't help with that.")) }
        let cast = await pipeline().proposeCast(title: "T", authors: ["William Smith"], cleaned: "x", depthNote: "")
        XCTAssertEqual(cast.speakers[1].name, "William")
        XCTAssertEqual(cast.speakers[1].gender, "male")       // not silently female
    }

    func testCastLeavesTrulyUnknownGenderUnset() async {
        MockLLM.install { _ in
            (200, MockLLM.chatReply(#"{"speakers":[{"role":"Interviewer","gender":"female","name":"Mia"},{"role":"Scientist","name":"Xyzzy"}],"authors":[]}"#))
        }
        let cast = await pipeline().proposeCast(title: "T", authors: ["Xyzzy Q"], cleaned: "x", depthNote: "")
        XCTAssertNil(cast.speakers[1].gender)
    }

    func testCastFillsGuestGenderFromTheAuthorList() async {
        MockLLM.install { _ in
            (200, MockLLM.chatReply(#"{"speakers":[{"role":"Interviewer","gender":"female","name":"Mia"},{"role":"Scientist","name":"Kim"}],"authors":[{"name":"Kim Park","gender":"male"}]}"#))
        }
        let cast = await pipeline().proposeCast(title: "T", authors: ["Kim Park"], cleaned: "x", depthNote: "")
        XCTAssertEqual(cast.speakers[1].gender, "male")
        XCTAssertEqual(cast.authorGenders, ["Kim Park": "male"])
    }

    func testChatErrorsFallBackInsteadOfThrowing() async {
        MockLLM.install { _ in (500, Data()) }
        let cast = await pipeline().proposeCast(title: "T", authors: ["Ada Lovelace"], cleaned: "x", depthNote: "")
        XCTAssertEqual(cast.speakers.count, 2)
    }
}

/// Secrets never land in user defaults.
final class LLMSettingsPersistenceTests: PapertalkTestCase {
    func testPersistedFormDropsTheTypedKey() throws {
        let s = LLMSettings(baseUrl: "http://llm", apiKey: "sk-secret", model: "m", keyEnv: "")
        XCTAssertEqual(s.persisted.apiKey, "")
        XCTAssertEqual(s.persisted.baseUrl, "http://llm")
        XCTAssertEqual(s.persisted.model, "m")
        let json = String(decoding: try JSONEncoder().encode(s.persisted), as: UTF8.self)
        XCTAssertFalse(json.contains("sk-secret"))
    }

    func testServerConfigRoundTrip() throws {
        let c = ServerConfig(apiBase: "http://host:9170", token: "t")
        let back = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
