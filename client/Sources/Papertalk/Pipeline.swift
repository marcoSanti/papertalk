import Foundation
import PDFKit
import AppKit

// MARK: - Local generation pipeline (self-hosted, no external compute server).
//
// Kept deliberately single-stage: extract text (PDFKit) -> one LLM call that
// returns a Transcript JSON -> PlayerController reads the transcript live via
// AVSpeechSynthesizer (no audio file is baked; local mode already streams).

struct PipelineResult {
    var transcript: Transcript
    var title: String
    var authors: [String]
}

/// Structured bibliographic metadata extracted from a paper by the LLM.
struct PaperMeta {
    var title: String = ""
    var authors: [String] = []
    var affiliations: [String] = []
    var doi: String = ""
    var tags: [String] = []
}

enum PipelineError: Error, LocalizedError {
    case noText, llm(String)
    var errorDescription: String? {
        switch self {
        case .noText: return "Could not extract text from PDF"
        case .llm(let m): return "LLM: \(m)"
        }
    }
}

enum Parsers {
    /// Parse "Name: text" dialogue lines into turns, tolerating the model
    /// occasionally mis-labeling a speaker or wrapping in prose.
    static func dialogue(from raw: String, names: [String]) -> [Transcript.Turn] {
        let lowNames = names.map { $0.lowercased() }
        var turns: [Transcript.Turn] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let speaker = String(trimmed[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Normalize the speaker to one of our names if it matches, else skip.
            guard let match = lowNames.firstIndex(where: { speaker.lowercased().hasPrefix($0) }) else { continue }
            turns.append(Transcript.Turn(speaker: names[match], text: text))
        }
        return turns
    }
}

struct LocalPipeline {
    var baseUrl: String
    var apiKey: String
    var model: String
    /// Optional hook for emitting progress lines; no-ops when unset.
    var log: (String) -> Void = { _ in }
    /// Optional hook for live progress: fraction (0...1) + current stage label.
    /// Drives the import progress bar in the UI; no-ops when unset.
    var onProgress: (Double, String) -> Void = { _, _ in }

    init(baseUrl: String, apiKey: String, model: String) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
    }

    /// Extract text from a PDF via AppKit's PDFKit.
    static func extractText(_ pdf: Data) -> String {
        guard let doc = PDFDocument(data: pdf) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string { out += text + "\n" }
        }
        return out
    }

    /// List model ids from an OpenAI-compatible `/models` endpoint.
    func listModels() async throws -> [String] {
        let url = URL(string: baseUrl.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + "/models")!
        var req = URLRequest(url: url)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await Self.send(req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PipelineError.llm("models HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["data"] as? [[String: Any]] else {
            throw PipelineError.llm("could not read /models")
        }
        return models.compactMap { $0["id"] as? String }
    }

    /// Ask the LLM to pull bibliographic metadata (title, authors, affiliations,
    /// DOI, tags) out of the paper's raw text. Best-effort: returns empty fields
    /// if the model fails or returns unusable JSON, never throws.
    func extractMeta(text: String, fallbackTitle: String) async throws -> PaperMeta {
        let system = "You extract bibliographic metadata from a research paper's raw OCR/PDF text. "
            + "Return ONLY a JSON object, no markdown, exactly: "
            + #"{"title": string, "authors": [string], "affiliations": [string], "doi": string, "tags": [string]}"#
            + "\n- title: the paper's real title (clean, not the filename). If you cannot tell, return \"\"."
            + "\n- authors: full author names in order. Empty if unknown."
            + "\n- affiliations: institution/department strings, deduplicated. Empty if unknown."
            + "\n- doi: the DOI when present (e.g. \"10.1016/j.jpdc.2017.07.010\"), else \"\"."
            + "\n- tags: 3-6 short topical keywords (e.g. \"reinforcement-learning\", \"distributed-systems\") describing the research. Never empty unless the text is unusable."
        let user = String(text.prefix(20_000))  // title/authors/DOI live near the top; keeps the call cheap
        let raw = (try? await chat(system: system, user: user, maxTokens: 1500)) ?? ""
        guard let json = Self.extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: json.data(using: .utf8)! ) as? [String: Any] else {
            return PaperMeta(title: fallbackTitle)
        }
        func str(_ k: String) -> String { (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func arr(_ k: String) -> [String] {
            guard let a = obj[k] as? [Any] else { return [] }
            return a.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var meta = PaperMeta(title: str("title"), authors: arr("authors"),
                             affiliations: arr("affiliations"), doi: str("doi"), tags: arr("tags"))
        if meta.title.isEmpty { meta.title = fallbackTitle }
        if meta.tags.isEmpty { meta.tags = ["paper"] }
        return meta
    }

    /// Turn a paper into a podcast transcript.
    ///
    /// Faithful multi-stage port of the original Python ScriptGenerator:
    /// 1. The LLM plans the SECTION INDEX and OUTLINE (titles, goals, section
    ///    refs, weights) from the raw paper.
    /// 2. Each outline segment is then WRITTEN by the LLM in a separate call, with
    ///    style + spoken rules, position rules, previously-covered points and a
    ///    rolling window of recent turns for consistency.
    /// 3. Methodology segments are delivered as FULL-LENGTH expert monologues,
    ///    chunked by source size so the audio scales with the paper.
    func generateTranscript(text: String, depth: Depth = .inDepth, depthNote: String = "") async throws -> PipelineResult {
        let cleaned = String(text.prefix(240_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PipelineError.noText }
        let lines = cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = lines.first.map { String($0.prefix(200)) } ?? "Untitled"
        let authors = detectAuthors(lines: lines)
        let expert = authors.first.flatMap(firstGivenName) ?? "Sam"
        let host = "Jordan"

        // Target episode length. Generous planned words because the model
        // generally under-writes the requested budget.
        let minutes = 30
        let minSeg = max(3, min(6, minutes / 5))
        let maxSeg = max(8, min(18, minutes / 2))
        let plannedWords = minutes * 220

        var plan = try await planScript(cleaned: cleaned, title: title, host: host, expert: expert,
                                        depth: depth, depthNote: depthNote, minutes: minutes,
                                        minSeg: minSeg, maxSeg: maxSeg, plannedWords: plannedWords)

        // Distribute the word budget across segments by weight, with a floor so
        // short segments still get a plausible length.
        let sumWeight = plan.segments.map { $0.weight }.reduce(0, +)
        var targets: [Int] = plan.segments.map { seg in
            let raw = Int((Double(plannedWords) * seg.weight / sumWeight).rounded())
            return max(250, raw)
        }

        log("Planned \(plan.sections.count) sections, \(plan.segments.count) segments (~\(minutes) min, \(plannedWords) words)")

        var history: [Transcript.Turn] = []
        var segments: [Transcript.Segment] = []
        let total = plan.segments.count
        for (k, seg) in plan.segments.enumerated() {
            onProgress(Double(k) / Double(max(total, 1)),
                       "Segment \(k + 1)/\(total): \(seg.title)")
            log("— Segment \(k + 1)/\(plan.segments.count): \"\(seg.title)\" (\(seg.monologue ? "monologue" : "dialogue"), ~\(targets[k]) words)")
            let turns: [Transcript.Turn]
            if seg.monologue {
                turns = try await writeMonologue(seg, index: k, plan: plan, cleaned: cleaned, expert: expert,
                                                 targetWords: targets[k])
            } else {
                turns = try await writeDialogue(seg, index: k, plan: plan, cleaned: cleaned, host: host, expert: expert,
                                                history: history, targetWords: targets[k], depthGuide: plan.depthGuide)
            }
            log("    ✓ wrote \(turns.count) turns (~\(turns.reduce(0) { $0 + $1.text.count }) chars); \(history.count + turns.count) turns so far")
            history.append(contentsOf: turns)
            segments.append(Transcript.Segment(title: seg.title, turns: turns))
        }

        let speakers = [
            Transcript.Speaker(name: host, persona: "host"),
            Transcript.Speaker(name: expert, persona: "expert"),
        ]
        let transcript = Transcript(paperTitle: title, speakers: speakers, segments: segments)
        return PipelineResult(transcript: transcript, title: title, authors: authors)
    }

    // ------------------------------------------------------------- plan
    private struct PlanSection: Codable { var title: String; var minSec: Int }
    private struct PlanSegment: Codable {
        var title: String; var goal: String; var sections: [Int]?; var keyPoints: [String]? = [];
        var weight: Double; var monologue: Bool; var targetWords: Int = 0
    }
    private struct Plan: Codable {
        var sections: [PlanSection]; var segments: [PlanSegment]; var tags: [String]? = []
        var depthGuide: String = ""
    }

    private func planScript(cleaned: String, title: String, host: String, expert: String, depth: Depth,
                            depthNote: String, minutes: Int, minSeg: Int, maxSeg: Int,
                            plannedWords: Int) async throws -> Plan {

        var depthGuide: String
        switch depth {
        case .summary:
            depthGuide = "DEPTH: SUMMARY. Overview-style episode for a general audience. Summarise method and results at a high level; no section is read verbatim."
        case .custom:
            depthGuide = depthNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "DEPTH: IN-DEPTH. Cover methods and results fully, including technical detail."
                : "USER-REQUESTED DEPTH:\n" + depthNote
        case .inDepth:
            depthGuide = "DEPTH: IN-DEPTH. Cover methods and results fully and technically, so a student could re-derive the work."
        }
        let outlineInstructions = """
        You are planning a two-speaker podcast episode about a research paper. First break the paper into an ordered, numbered SECTION INDEX of its major sections (Abstract, Introduction, Related Work, Method/Model/Approach, Experiments/Evaluation, Results, Discussion, Conclusion, ... Keep the paper's own titles where clear). Then design an OUTLINE of listening segments covering the whole paper.

        OUTLINE & SEGMENTATION RULES:
        - Target total length ≈ \(minutes) minutes.
        - Use no less than \(minSeg) and no more than \(maxSeg) segments.
        - The technical heart of the paper (Method / Model / Approach / Algorithm sections) MUST be its own segment(s) with "monologue": true — these are delivered as a long, faithful, full-length spoken walkthrough.
        - Every section in the section index must be covered by at least one segment (map each segment to the 1-based indices of the sections it covers via "sections").
        - Give each segment: a clear spoken goal ("explain the key idea of attention"), the key_points that must be hit, and a "weight" (0–1, sums used to split the ~\(plannedWords) planned words so longer/more technical parts get more airtime).
        - \(depthGuide)

        Respond with ONLY a JSON object, no markdown, exactly:
        {"tags": [short keywords], "sections": [{"title": string, "min_sec": int}], "segments": [{"title": string, "goal": string, "sections": [int], "key_points": [string], "weight": number, "monologue": boolean}]}
        """
        let system = "You are an expert science-podcast editor. You respond with strict JSON only."
        log("Outline: requesting section index + segment plan for \(title)…")

        var raw = try await chat(system: system, user: outlineInstructions + "\n\n=== PAPER ===\n" + cleaned, maxTokens: 9000)
        var plan = Self.decodePlanLenient(raw)
        if plan == nil {
            // One repair attempt: ask for the JSON alone.
            log("Outline not decodable — asking LLM to re-emit strict JSON")
            let fix = "Your previous reply was not valid JSON for my schema. Return ONLY a single JSON object matching exactly: "
                + #"{"sections": [{"title": string, "min_sec": int}], "segments": [{"title": string, "goal": string, "sections": [int], "key_points": [string], "weight": number, "monologue": boolean}]}"#
            raw = try await chat(system: system, user: fix + "\n\nPAPER:\n" + cleaned, maxTokens: 9000)
            plan = Self.decodePlanLenient(raw)
        }
        guard var p = plan, !p.segments.isEmpty else {
            let sample = Self.extractJSON(raw) ?? String(raw.prefix(600))
            throw PipelineError.llm("could not decode outline from LLM. Reply was:\n\(sample.prefix(800))")
        }
        p.depthGuide = depthGuide
        return p
    }

    /// Lenient outline decoder: never throws, tolerates missing/renamed keys and
    /// type drift so a slightly-off model reply doesn't kill the run.
    private static func decodePlanLenient(_ raw: String) -> Plan? {
        guard let json = extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as? [String: Any] else { return nil }

        func asStr(_ v: Any?) -> String? { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        func asInt(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue ?? Int(asStr(v) ?? "") }
        func asDouble(_ v: Any?) -> Double? { (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? Double(asStr(v) ?? "") }
        func asBool(_ v: Any?) -> Bool {
            if let b = v as? Bool { return b }
            if let i = (v as? NSNumber)?.doubleValue { return i != 0 }
            return (asStr(v)?.lowercased() ?? "") == "true"
        }
        func asStrArray(_ v: Any?) -> [String] {
            if let a = v as? [String] { return a }
            if let a = v as? [Any] { return a.compactMap { asStr($0) } }
            return []
        }

        var sections: [PlanSection] = []
        if let sarr = obj["sections"] as? [Any] {
            for s in sarr {
                guard let d = s as? [String: Any], let t = asStr(d["title"]), !t.isEmpty else { continue }
                sections.append(PlanSection(title: t, minSec: asInt(d["min_sec"]) ?? 30))
            }
        }

        var segments: [PlanSegment] = []
        if let garr = obj["segments"] as? [Any] {
            for g in garr {
                guard let d = g as? [String: Any], let t = asStr(d["title"]), !t.isEmpty else { continue }
                let refs = (d["sections"] as? [Any])?.compactMap { asInt($0) } ?? []
                let seg = PlanSegment(
                    title: t,
                    goal: asStr(d["goal"]) ?? "",
                    sections: refs,
                    keyPoints: asStrArray(d["key_points"]),
                    weight: asDouble(d["weight"]) ?? 0.5,
                    monologue: asBool(d["monologue"]),
                    targetWords: 0)
                segments.append(seg)
            }
        }
        guard !sections.isEmpty, !segments.isEmpty else { return nil }
        let tags = asStrArray(obj["tags"])
        return Plan(sections: sections, segments: segments, tags: tags, depthGuide: "")
    }

    // ------------------------------------------------------ dialogue segment
    private func writeDialogue(_ seg: PlanSegment, index k: Int, plan: Plan, cleaned: String,
                               host: String, expert: String, history: [Transcript.Turn],
                               targetWords: Int, depthGuide: String) async throws -> [Transcript.Turn] {

        let n = plan.segments.count
        let position = positionRule(index: k, count: n, host: host, expert: expert)

        let titles = plan.segments.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let kps = (seg.keyPoints ?? []).map { "- \($0)" }.joined(separator: "\n")
        let covered = plan.segments[0..<min(k, plan.segments.count)].flatMap { ($0.keyPoints ?? []) }
        let coveredStr = covered.isEmpty ? "None yet." : covered.map { "- \($0)" }.joined(separator: "\n")
        let recent = history.suffix(8).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")

        let spoken = """
        WRITE FOR THE EAR — the text will be read aloud by a text-to-speech engine:
        - Plain sentences only. No markdown, bullets, headings, emojis, stage directions, or sound effects.
        - No citation markers like [12] or (Smith et al., 2020); say "earlier work by Smith and colleagues" if needed.
        - Verbalise math: "x squared", "the sum over all tokens of the log probability"; explain what an equation means rather than reading long formulas symbol by symbol.
        - Say numbers as they are spoken: "about ninety-two point four percent", "ten to the minus three".
        - Expand abbreviations the first time they appear.
        - Mostly 1–5 sentences per turn; vary rhythm with occasional short reactions ("Right.", "Wait, so...").
        - Stay faithful to the source. Never invent results, numbers or claims.
        """

        let segPrompt = """
        SEGMENT \(k + 1) of \(n) — Title: "\(seg.title)"
        GOAL: \(seg.goal)
        MUST COVER (key points):
        \(kps)

        TARGET LENGTH: about \(targetWords) words. Write a full, detailed conversation — do not rush or truncate.

        OTHER SEGMENTS IN THIS EPISODE (do not repeat them):
        \(titles)

        ALREADY COVERED EARLIER (do not repeat these points):
        \(coveredStr)

        RECENT TURNS FROM THE EPISODE SO FAR (match their tone and continue naturally; do not re-say them):
        \(recent.isEmpty ? "No turns yet." : recent)

        POSITION IN THE EPISODE:
        \(position)

        FORMAT: dialogue only, one turn per line, as
        \(host): ...
        \(expert): ...
        No headings, no notes. Keep it a natural back-and-forth conversation.

        SOURCE MATERIAL:
        =================
        \(cleaned)
        """

        let system = "You are a scriptwriter writing a faithful, detailed, two-speaker spoken podcast episode from a scientific paper. "
            + "\(host) is the HOST (sharp, technical, asks the questions a smart listener would, asks for intuition, signposts transitions). "
            + "\(expert) is the EXPERT, the paper's first author (carries the technical content, exact figures, never condescending).\n\n" + spoken

        for _ in 0..<2 {
            let raw = try await chat(system: system, user: segPrompt, maxTokens: 9000)
            let turns = Parsers.dialogue(from: raw, names: [host, expert])
            if turns.count >= 2, Set(turns.map { $0.speaker }).count == 2 {
                return turns
            }
        }
        // Last resort: treat everything written as one long expert turn rather than
        // failing the whole episode.
        let raw = try await chat(system: system, user: segPrompt + "\n\nFORMAT: output ONLY one single long turn spoken by \(expert).",
                                 maxTokens: 9000)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [Transcript.Turn(speaker: expert, text: text)]
    }

    // --------------------------------------------- methodology monologue segment
    private func writeMonologue(_ seg: PlanSegment, index k: Int, plan: Plan, cleaned: String,
                                expert: String, targetWords: Int) async throws -> [Transcript.Turn] {
        // Grab the raw text of the sections this segment covers (only used as the
        // faithful source the LLM restates — the outline itself is LLM-driven).
        let methodText = sourceForSections(plan, seg, cleaned)
        let source = methodText.isEmpty ? cleaned : methodText
        let blocks = blockText(source, max: 40_000)
        log("    method source: \(source.count) chars → \(blocks.count) blocks")

        var turns: [Transcript.Turn] = []
        for (i, block) in blocks.enumerated() {
            guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let position: String
            if blocks.count == 1 { position = "This is the only block." }
            else if i == 0 { position = "This is block 1 (the first part)." }
            else if i == blocks.count - 1 { position = "This is the final block." }
            else { position = "This block continues the monologue; keep the same voice and flow." }

            let system = "You are \(expert), the paper's first author, explaining the method aloud "
                + "to a listener who wants to re-derive it. Build a SINGLE continuous monologue that reproduces "
                + "the paper's method FAITHFULLY and at FULL length — do not summarise, condense, or drop any step, "
                + "definition, parameter, equation, assumption, dataset, baseline, or number. The source is raw OCR/PDF "
                + "text full of extraction artifacts (broken hyphenated words, mangled symbols and equations): repair those "
                + "so it reads as clean, natural spoken prose, and verbalise every equation in words. Keep the paper's own "
                + "framing and every number exactly as stated. Never add content the source does not state.\n\n"
                + "WRITE FOR THE EAR: plain sentences, no markdown, no headings, no stage directions.\n"
                + position
                + "\n\nOutput ONLY the narration text — no speaker name, no notes."

            let raw = try await chat(system: system, user: "METHOD TEXT (block \(i + 1)):\n" + block, maxTokens: 9000)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            log("    block \(i + 1)/\(blocks.count): +\(text.count) chars")
            if !text.isEmpty { turns.append(Transcript.Turn(speaker: expert, text: text)) }
        }
        return turns
    }

    private func sourceForSections(_ plan: Plan, _ seg: PlanSegment, _ cleaned: String) -> String {
        guard let refs = seg.sections, !refs.isEmpty else { return "" }
        let wanted = refs.compactMap { $0 - 1 < plan.sections.count ? plan.sections[$0 - 1].title : nil }
        guard !wanted.isEmpty else { return "" }
        let local = splitSections(cleaned)
        let matched = local.filter { s in
            wanted.contains { w in
                let a = presentable(s.title).lowercased().trimmingCharacters(in: .whitespaces)
                let b = w.lowercased().trimmingCharacters(in: .whitespaces)
                return a == b || (a.count > 4 && a.contains(b)) || (b.count > 4 && b.contains(a))
            }
        }.map { $0.text }
        return matched.joined(separator: "\n\n")
    }

    private func positionRule(index k: Int, count n: Int, host: String, expert: String) -> String {
        func r(_ speaker: String) -> String { speaker }
        if n == 1 {
            return "This is the ONLY segment of the episode. \(r(host)) opens by introducing the paper, its authors and the topic, then you have a complete conversation from start to finish, landing a satisfying ending."
        }
        if k == 0 {
            return "This is the FIRST segment. \(r(host)) starts the episode by introducing the paper, its authors and the topic. Leave room for the later segments; do not jump to conclusions."
        }
        if k == n - 1 {
            return "This is the LAST segment. Build on what was covered and move the conversation to a satisfying conclusion and wrap-up."
        }
        return "This is a MIDDLE segment. \(r(host)) briefly signals this part's goal, then keep going. Do not reintroduce the paper or wrap up the episode."
    }

    // ------------------------------------------------------------- helpers

    /// Perform an OpenAI request with a generous timeout and a small number of
    /// retries (with backoff). Retries on transport-level failures (connection
    /// drop / timeout) and transient 5xx responses; no request is buffered, so
    /// re-sending a chat call is safe.
    private static func send(_ req: URLRequest, attempts: Int = 3) async throws -> (Data, URLResponse) {
        var request = req
        request.timeoutInterval = 120
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let (data, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, (500..<600).contains(http.statusCode) {
                    lastError = PipelineError.llm("server error HTTP \(http.statusCode)")
                } else {
                    return (data, resp)
                }
            } catch is URLError {
                lastError = PipelineError.llm("network error (attempt \(attempt + 1))")
            }
            if attempt < attempts - 1 {
                // exponential backoff, capped.
                let delay = Double(min(1 << attempt, 8))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? PipelineError.llm("request failed after \(attempts) attempts")
    }

    private func chat(system: String, user: String, maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.5,
            "max_tokens": maxTokens
        ]
        var req = URLRequest(url: URL(string: baseUrl.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            .hasSuffix("/chat/completions") ? baseUrl : baseUrl + "/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await Self.send(req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PipelineError.llm("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let raw = content["content"] as? String else {
            throw PipelineError.llm("could not read LLM response")
        }
        return raw
    }

    private struct PaperSection {
        let title: String
        let text: String
    }

    private static let knownSections: Set<String> = [
        "abstract", "introduction", "background", "related work", "related works",
        "preliminaries", "method", "methods", "methodology", "approach", "model",
        "materials and methods", "experimental setup", "experiments", "experimental results",
        "results", "results and discussion", "evaluation", "analysis", "discussion",
        "limitations", "future work", "conclusion", "conclusions", "concluding remarks",
        "acknowledgments", "acknowledgements", "references", "bibliography", "appendix",
    ]

    private static let methodologyTitles: Set<String> = [
        "method", "methods", "methodology", "approach", "model", "the model",
        "our method", "our approach", "proposed method", "proposed approach",
        "methods and materials", "materials and methods", "experimental setup",
        "preliminaries", "problem setup", "methods and experiments", "algorithm",
    ]

    private func splitSections(_ text: String) -> [PaperSection] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var sections: [PaperSection] = []
        var title = "Overview"
        var body: [String] = []
        func flush() {
            let joined = body.filter { !$0.isEmpty }.joined(separator: "\n")
            if !joined.isEmpty { sections.append(PaperSection(title: title, text: joined)) }
            body = []
        }
        for line in lines {
            if isHeading(line) {
                flush()
                title = presentable(line)
            } else if !line.isEmpty {
                body.append(line)
            }
        }
        flush()
        return sections.isEmpty ? [PaperSection(title: "Paper", text: text)] : sections
    }

    private func isHeading(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 80 else { return false }
        let stripped = stripNumbering(line)
        let low = stripped.lowercased()
        if Self.knownSections.contains(low) { return true }
        // Numbered heading like "1. Introduction" / "3.1 Model" / "IV. Method".
        let numbered = line.first?.isNumber == true && line.contains(".")
        return numbered && low.split(separator: " ").count <= 4 && !low.hasSuffix(".")
    }

    private func isMethodology(_ title: String) -> Bool {
        let low = stripNumbering(title).lowercased()
        if Self.methodologyTitles.contains(low) { return true }
        return ["method", "methodology", "approach", "experimental setup"].contains { low.contains($0) }
    }

    private func stripNumbering(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        while let r = s.range(of: #"^([\d.]+|[ivxlc]+\.?|[a-z])\.?\s+"#, options: .regularExpression) {
            s = String(s[r.upperBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentable(_ title: String) -> String {
        let s = stripNumbering(title)
        return s.isEmpty ? title : s
    }

    /// Split text into pieces no larger than `max`, preferring sentence boundaries.
    private func blockText(_ text: String, max: Int) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return [t] }
        var out: [String] = []
        var cur = ""
        let sentences = t.components(separatedBy: "\n\n").flatMap { p in
            p.count > max ? p.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" }).map { String($0) } : [p]
        }
        for s in sentences {
            let piece = s.isEmpty ? "" : (s.last == "." ? s : s + ".")
            if cur.count + piece.count > max && !cur.isEmpty {
                out.append(cur)
                cur = piece
            } else {
                cur += (cur.isEmpty ? "" : " ") + piece
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func extractJSON(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Take everything from the first "{" to the last "}", ignoring any
        // prose the model added before/after and code fences.
        guard s.contains("{"),
              let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}") else { return nil }
        return String(s[start...end])
    }

    /// Best-effort author list from the first lines after the title: short
    /// lines of names, comma- or period-joined, that are not sentences.
    private func detectAuthors(lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if line.count > 90 { break }
            let looksLikeSentence = line.hasSuffix(".") && line.split(separator: " ").count > 6 && !line.contains(",")
            if looksLikeSentence { break }
            let tokens = line.replacingOccurrences(of: ",", with: " ", options: [])
                .split(separator: " ")
                .prefix(6)
                .joined(separator: " ")
            if tokens.isEmpty { break }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            out += parts.count > 1 ? parts : [tokens]
            if out.count >= 3 { break }
        }
        return out
    }

    private func firstGivenName(_ full: String) -> String? {
        let first = full.replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").first.map(String.init) ?? ""
        return first.count > 1 ? first : nil
    }
}