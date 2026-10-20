import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
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
    /// Editable prompts (only the reply schemas and dialogue format stay hardcoded).
    var prompts: PromptSettings = .defaults
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

    /// Direct-read transcript: chunk the extracted text into turns so it is
    /// read out loud as-is, with no LLM rewriting. Only collapses blank lines and
    /// merges short lines, and caps each turn so synthesis stays snappy.
    static func readThroughTurns(_ text: String) -> [Transcript.Turn] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 1 }
        var turns: [Transcript.Turn] = []
        var buf = ""
        for line in lines {
            if !buf.isEmpty, buf.count + line.count > 1400 {
                turns.append(Transcript.Turn(speaker: "Reader", text: buf))
                buf = line
            } else {
                buf = buf.isEmpty ? line : buf + " " + line
            }
        }
        if !buf.isEmpty { turns.append(Transcript.Turn(speaker: "Reader", text: buf)) }
        return turns
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
        let system = prompts.metadata + "\n\nReturn ONLY a JSON object, no markdown, exactly: "
            + #"{"title": string, "authors": [string], "affiliations": [string], "doi": string, "tags": [string]}"#
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
    ///
    /// `summaryMinutes` is the summary's ceiling (default `SummaryLength.defaultMinutes`);
    /// other depths ignore it.
    func generateTranscript(text: String, depth: Depth = .inDepth, depthNote: String = "", summaryMinutes: Int? = nil,
                            host: String? = nil, expert: String? = nil) async throws -> PipelineResult {
        let cleaned = String(text.prefix(240_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PipelineError.noText }
        let lines = cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = lines.first.map { String($0.prefix(200)) } ?? "Untitled"
        let authors = detectAuthors(lines: lines)
        let expert = expert?.nonEmpty ?? authors.first.flatMap(firstGivenName) ?? "Sam"
        let host = host?.nonEmpty ?? "Jordan"

        // Episode length per depth, in spoken words. Kokoro reads about 145
        // words a minute at the default pace (measured on real episodes).
        let wordsPerMinute = 145.0
        let plannedWords: Int
        /// Hard ceiling on the whole script, enforced while writing (summary only).
        var wordCap: Int? = nil
        switch depth {
        case .summary:
            // Up to the chosen length: aim a little under (30 of 35 minutes),
            // since the model tends to overshoot.
            let ceiling = Double(summaryMinutes ?? SummaryLength.defaultMinutes)
            plannedWords = Int(ceiling * 6 / 7 * wordsPerMinute)
            wordCap = Int(ceiling * wordsPerMinute)
        case .inDepth, .custom, .direct:
            // As long as the paper needs: scale with the source, never under ~30 min.
            let sourceWords = cleaned.split(whereSeparator: \.isWhitespace).count
            plannedWords = max(Int(30 * wordsPerMinute), Int(Double(sourceWords) * 0.7))
        }
        let minutes = max(1, Int((Double(plannedWords) / wordsPerMinute).rounded()))
        let minSeg = minutes < 10 ? 2 : max(3, min(6, minutes / 5))
        // A short summary gets few segments, or their minimum lengths alone would overrun it.
        let maxSeg = max(minSeg + 1, min(18, minutes / 2))

        var plan = try await planScript(cleaned: cleaned, title: title, host: host, expert: expert,
                                        depth: depth, depthNote: depthNote, minutes: minutes,
                                        minSeg: minSeg, maxSeg: maxSeg, plannedWords: plannedWords)

        // Full-length method monologues are the in-depth format. The outline
        // prompt asks for them regardless of depth, so enforce it here: any
        // other depth gets a budgeted dialogue instead of a verbatim read-through.
        if depth != .inDepth {
            let forced = plan.segments.filter(\.monologue).count
            for i in plan.segments.indices { plan.segments[i].monologue = false }
            if forced > 0 { log("Depth \(depth.label): \(forced) monologue segment(s) turned into dialogue") }
        }

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
            // Summary: re-split what's left of the ceiling over the remaining
            // segments, so an over-long early segment can't push the episode
            // past its length (and the ending still gets its share).
            if let cap = wordCap {
                let written = Self.wordCount(history)
                let remainingWeight = plan.segments[k...].map(\.weight).reduce(0, +)
                let share = remainingWeight > 0 ? seg.weight / remainingWeight : 1
                let budget = Int(Double(max(0, cap - written)) * share)
                // The floor keeps an ending, but must not overrun a short episode by itself.
                let floor = min(120, cap / max(1, 2 * total))
                targets[k] = max(floor, min(targets[k], budget))
            }
            log("— Segment \(k + 1)/\(plan.segments.count): \"\(seg.title)\" (\(seg.monologue ? "monologue" : "dialogue"), ~\(targets[k]) words)")
            var turns: [Transcript.Turn]
            if seg.monologue {
                turns = try await writeMonologue(seg, index: k, plan: plan, cleaned: cleaned, host: host,
                                                 expert: expert, history: history,
                                                 targetWords: targets[k])
            } else {
                turns = try await writeDialogue(seg, index: k, plan: plan, cleaned: cleaned, host: host, expert: expert,
                                                history: history, targetWords: targets[k], depthGuide: plan.depthGuide,
                                                limited: wordCap != nil)
                // The model often writes well past a short target, so a fixed-length
                // episode checks what came back rather than trusting the request.
                if wordCap != nil {
                    turns = try await fitDialogue(turns, to: targets[k], host: host, expert: expert)
                }
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
            depthGuide = prompts.depthSummary
        case .custom:
            let note = depthNote.trimmingCharacters(in: .whitespacesAndNewlines)
            depthGuide = note.isEmpty ? prompts.depthInDepth : PromptSettings.fill(prompts.depthCustom, ["note": note])
        case .inDepth:
            depthGuide = prompts.depthInDepth
        case .direct:
            depthGuide = ""
        }
        let rules = PromptSettings.fill(prompts.outlineRules, [
            "minutes": "\(minutes)", "minSeg": "\(minSeg)", "maxSeg": "\(maxSeg)",
            "plannedWords": "\(plannedWords)", "depthGuide": depthGuide, "host": host, "expert": expert,
        ])
        let outlineInstructions = rules + """
        \n\nRespond with ONLY a JSON object, no markdown, exactly:
        {"tags": [short keywords], "sections": [{"title": string, "min_sec": int}], "segments": [{"title": string, "goal": string, "sections": [int], "key_points": [string], "weight": number, "monologue": boolean}]}
        """
        let system = prompts.outlineSystem
        log("Outline: requesting section index + segment plan for \(title)…")

        var raw = try await chat(system: system, user: outlineInstructions + "\n\n=== PAPER ===\n" + cleaned, maxTokens: 9000)
        var plan = Self.decodePlanLenient(raw)
        if plan == nil {
            // One repair attempt: ask for the JSON alone.
            log("Outline not decodable — asking LLM to re-emit strict JSON")
            let fix = prompts.outlineRepair + " Return ONLY a single JSON object matching exactly: "
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
                               targetWords: Int, depthGuide: String, limited: Bool = false) async throws -> [Transcript.Turn] {

        let n = plan.segments.count
        let position = positionRule(index: k, count: n, host: host, expert: expert)

        let titles = plan.segments.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let kps = (seg.keyPoints ?? []).map { "- \($0)" }.joined(separator: "\n")
        let covered = plan.segments[0..<min(k, plan.segments.count)].flatMap { ($0.keyPoints ?? []) }
        let coveredStr = covered.isEmpty ? "None yet." : covered.map { "- \($0)" }.joined(separator: "\n")
        let recent = history.suffix(8).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")

        let spoken = prompts.writeForEar

        let request = PromptSettings.fill(prompts.segmentRequest, [
            "segmentNumber": "\(k + 1)", "segmentCount": "\(n)", "segmentTitle": seg.title, "goal": seg.goal,
            "keyPoints": kps, "targetWords": "\(targetWords)", "otherSegments": titles, "covered": coveredStr,
            "recentTurns": recent.isEmpty ? "No turns yet." : recent, "position": position,
            "host": host, "expert": expert,
        ])
        let limit = limited ? "\n\n" + PromptSettings.fill(prompts.lengthLimit, ["maxWords": "\(targetWords)"]) : ""
        // The format is what `Parsers.dialogue` reads, so it isn't part of the editable prompt.
        let segPrompt = request + limit + """


        FORMAT: dialogue only, one turn per line, as
        \(host): ...
        \(expert): ...
        No headings, no notes. Keep it a natural back-and-forth conversation.

        SOURCE MATERIAL:
        =================
        \(cleaned)
        """

        let system = PromptSettings.fill(prompts.dialoguePersona, ["host": host, "expert": expert])
            + "\n\n" + PromptSettings.fill(spoken, ["host": host, "expert": expert])

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

    /// A segment of a fixed-length episode that ran more than 15% over its
    /// target: ask once for a condensed version, then cut whatever is still over.
    private func fitDialogue(_ turns: [Transcript.Turn], to target: Int, host: String, expert: String) async throws -> [Transcript.Turn] {
        let words = Self.wordCount(turns)
        guard words > target + target * 15 / 100 else { return turns }
        log("    segment ran long (\(words) of ~\(target) words) — condensing")
        let tokens = ["targetWords": "\(target)", "host": host, "expert": expert]
        let system = PromptSettings.fill(prompts.dialoguePersona, tokens) + "\n\n" + PromptSettings.fill(prompts.writeForEar, tokens)
        let request = PromptSettings.fill(prompts.condense, tokens) + """


        FORMAT: dialogue only, one turn per line, as
        \(host): ...
        \(expert): ...

        DIALOGUE:
        \(turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"))
        """
        var best = turns
        let raw = try await chat(system: system, user: request, maxTokens: 9000)
        let shorter = Parsers.dialogue(from: raw, names: [host, expert])
        if shorter.count >= 2, Self.wordCount(shorter) < words { best = shorter }
        guard Self.wordCount(best) > target + target * 15 / 100 else { return best }
        let cut = Self.trimTurns(best, toWords: target)
        log("    still long (\(Self.wordCount(best)) words) — cut to \(Self.wordCount(cut))")
        return cut
    }

    static func wordCount(_ turns: [Transcript.Turn]) -> Int {
        turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Cut a dialogue to about `budget` words: whole turns from the start, the
    /// turn that doesn't fit cut at a sentence, and the last turn (its ending
    /// or hand-off) kept when there's room for it.
    static func trimTurns(_ turns: [Transcript.Turn], toWords budget: Int) -> [Transcript.Turn] {
        func count(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        /// The leading whole sentences of `text` within `maxWords` (nil if not even one fits).
        func leading(_ text: String, _ maxWords: Int) -> String? {
            var out = "", used = 0
            text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
                guard let sentence else { return }
                let w = count(sentence)
                if used + w > maxWords { stop = true; return }
                out += sentence; used += w
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard wordCount(turns) > budget, let last = turns.last else { return turns }
        let reserve = min(count(last.text), budget / 3)
        var out: [Transcript.Turn] = []
        var used = 0
        for t in turns.dropLast() {
            let room = budget - reserve - used
            guard room > 0 else { break }
            if count(t.text) <= room {
                out.append(t); used += count(t.text)
            } else {
                if let s = leading(t.text, room) { out.append(Transcript.Turn(speaker: t.speaker, text: s)); used += count(s) }
                break
            }
        }
        if count(last.text) <= budget - used {
            out.append(last)
        } else if let s = leading(last.text, budget - used) {
            out.append(Transcript.Turn(speaker: last.speaker, text: s))
        }
        if out.isEmpty, let first = turns.first {
            // Not even one sentence fits: cut the first turn by words.
            let text = leading(first.text, budget)
                ?? first.text.split(whereSeparator: \.isWhitespace).prefix(max(1, budget)).joined(separator: " ")
            out = [Transcript.Turn(speaker: first.speaker, text: text)]
        }
        return out
    }

    // --------------------------------------------- methodology monologue segment
    private func writeMonologue(_ seg: PlanSegment, index k: Int, plan: Plan, cleaned: String,
                                host hostName: String, expert: String, history: [Transcript.Turn],
                                targetWords: Int) async throws -> [Transcript.Turn] {
        // Grab the raw text of the sections this segment covers (only used as the
        // faithful source the LLM restates — the outline itself is LLM-driven).
        let methodText = sourceForSections(plan, seg, cleaned)
        // If the outline's section titles can't be matched to the paper, don't
        // fall back to restating the whole paper (that produced 5,000-word turns).
        guard !methodText.isEmpty else {
            log("    method sections not found in the text — writing this segment as dialogue")
            return try await writeDialogue(seg, index: k, plan: plan, cleaned: cleaned, host: hostName, expert: expert,
                                            history: history, targetWords: targetWords, depthGuide: plan.depthGuide)
        }
        let source = methodText
        let blocks = blockText(source, max: 40_000)
        log("    method source: \(source.count) chars → \(blocks.count) blocks")

        var turns: [Transcript.Turn] = []
        for (i, block) in blocks.enumerated() {
            guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let position: String
            if blocks.count == 1 { position = prompts.blockOnly }
            else if i == 0 { position = prompts.blockFirst }
            else if i == blocks.count - 1 { position = prompts.blockLast }
            else { position = prompts.blockMiddle }
            let tokens = ["expert": expert, "host": hostName, "position": position]

            let system = PromptSettings.fill(prompts.monologuePersona, tokens)
                + "\n\n" + PromptSettings.fill(prompts.monologueRules, tokens)
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
        let template = n == 1 ? prompts.positionOnly
            : k == 0 ? prompts.positionFirst
            : k == n - 1 ? prompts.positionLast
            : prompts.positionMiddle
        return PromptSettings.fill(template, ["host": host, "expert": expert])
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

    static func extractJSON(_ raw: String) -> String? {
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

    /// Ask the LLM to cast the episode: who speaks, each person's gender and a
    /// suggested name. Used *after* metadata so the scientist's real author name
    /// can inform it. Falls back to a sensible two-person cast when the model is
    /// unreachable or returns unusable JSON.
    ///
    /// ponytail: the reported "how many voices" is capped at the interviewer +
    /// scientist pair the dialogue generator supports; a future N-speaker rewrite
    /// of planScript/writeDialogue would lift that ceiling.
    /// Ask the LLM for the paper's mind map. Asks once more when a main concept
    /// isn't broken down; throws only when no usable map comes back at all.
    func mindMap(title: String, text: String) async throws -> MindMap {
        // An object, not a bare array: `extractJSON` cuts from the first "{" to the last "}".
        let system = prompts.mindMap + """
        \n\nReturn ONLY a JSON object, no markdown or prose:
        {"nodes": [{"id": string, "label": string, "branch": "problem"|"method"|"evidence", "parent": string|null, "description": string, "core": string}],
         "links": [{"from": string, "to": string, "label": string}]}
        """
        let user = "Title: \(title)\n\nPAPER:\n" + String(text.prefix(60_000))
        log("Mind map: asking for the paper's key concepts…")
        let first = MindMap.parse(try await chat(system: system, user: user, maxTokens: 6000))
        if let first, first.isExpanded {
            log("Mind map: \(first.nodes.count) concepts, \(first.links.count) links")
            return first
        }
        log("Mind map: \(first == nil ? "reply unusable" : "a main concept wasn't broken down") — asking again")
        let second = MindMap.parse(try await chat(system: system, user: prompts.mindMapRetry + "\n\n" + user, maxTokens: 6000))
        guard let map = second ?? first else { throw PipelineError.llm("the mind map reply couldn't be read") }
        log("Mind map: \(map.nodes.count) concepts, \(map.links.count) links")
        return map
    }

    func proposeCast(title: String, authors: [String], cleaned: String, depthNote: String) async -> CastProposal {
        let scientistName = authors.first.flatMap(firstGivenName) ?? "Sam"
        let fallback = CastProposal(
            speakers: [
                ProposedSpeaker(role: "Interviewer", gender: "female", name: "Jordan"),
                ProposedSpeaker(role: "Scientist", gender: nil, name: scientistName),
            ],
            authorGenders: [:])
        // An object, not a bare array: `extractJSON` cuts from the first "{" to
        // the last "}", which mangles a top-level array.
        let system = prompts.cast + """
        \n\nReturn ONLY a JSON object, no markdown or prose:
        {"speakers": [{"role": string, "gender": "male"|"female", "name": string}],
         "authors": [{"name": string, "gender": "male"|"female"}]}
        """
        let user = "Title: \(title)\nAuthors: \(authors.joined(separator: ", "))\nMode: \(depthNote.isEmpty ? "In-depth discussion" : depthNote)\n\nPaper excerpt:\n\(cleaned.prefix(2500))"
        var cast = fallback
        if let raw = try? await chat(system: system, user: user, maxTokens: 700),
           let parsed = Self.parseCast(raw), !parsed.speakers.isEmpty {
            cast = parsed
        } else {
            log("Cast: model reply unusable, using the default cast")
        }
        // Fill any gender the model left out: from its author list, then from the name.
        for i in cast.speakers.indices where cast.speakers[i].gender == nil {
            let name = cast.speakers[i].name.lowercased()
            let fromAuthors = cast.authorGenders.first { full, _ in
                full.lowercased() == name || full.lowercased().split(separator: " ").first.map(String.init) == name
            }?.value
            if let g = fromAuthors ?? KokoroSpeech.guessGender(fromName: cast.speakers[i].name) {
                cast.speakers[i] = ProposedSpeaker(role: cast.speakers[i].role, gender: g, name: cast.speakers[i].name)
            }
        }
        return cast
    }

    private static func normalizeGender(_ any: Any?) -> String? {
        let g = (any as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        return ["male", "m", "man"].contains(g) ? "male" : ["female", "f", "woman"].contains(g) ? "female" : nil
    }

    /// Accepts the requested object, or a bare speakers array as older prompts produced.
    private static func parseCast(_ raw: String) -> CastProposal? {
        var speakerDicts: [[String: Any]] = []
        var authorDicts: [[String: Any]] = []
        if let json = extractJSON(raw), let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            speakerDicts = obj["speakers"] as? [[String: Any]] ?? []
            authorDicts = obj["authors"] as? [[String: Any]] ?? []
        }
        if speakerDicts.isEmpty, let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
           let data = String(raw[start...end]).data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            speakerDicts = arr
        }
        var speakers: [ProposedSpeaker] = []
        for d in speakerDicts {
            let role = (d["role"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !role.isEmpty, !name.isEmpty else { continue }
            speakers.append(ProposedSpeaker(role: role, gender: normalizeGender(d["gender"]), name: name))
        }
        var genders: [String: String] = [:]
        for d in authorDicts {
            if let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
               let g = normalizeGender(d["gender"]) {
                genders[name] = g
            }
        }
        return speakers.isEmpty ? nil : CastProposal(speakers: speakers, authorGenders: genders)
    }
}