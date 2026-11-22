// Everything the user configures, and where it is kept: the storage server, the LLM, where
// voices are synthesized, the editable LLM prompts and the custom-depth presets. Settings live
// in user defaults as JSON; API keys only ever in the Keychain (`KeychainStore`).

import Foundation
#if canImport(Security)
import Security
#endif

#if os(macOS)
/// Minimal Keychain string store (system framework — no dependencies) for LLM
/// API keys: one typed into Settings, or one sourced from an env var (so
/// GUI-launched apps, which don't inherit shell env vars, can still resolve it).
enum KeychainStore {
    private static let service = "com.papertalk.key"
    /// Off in the test suite: the login Keychain is the user's, whichever process asks.
    nonisolated(unsafe) static var isEnabled = true

    /// The query that finds `account`'s entry.
    private static func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store `value` under `account`, replacing what was there.
    static func set(_ value: String, account: String) {
        guard isEnabled else { return }
        var attrs = item(account)
        SecItemDelete(attrs as CFDictionary)
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }
    /// The string saved under `account`, if any.
    static func get(_ account: String) -> String? {
        guard isEnabled else { return nil }
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Remove `account`'s entry (no error if there is none).
    static func delete(_ account: String) {
        guard isEnabled else { return }
        SecItemDelete(item(account) as CFDictionary)
    }
}
#endif

// MARK: - Server configuration (persisted in the app)
/// Where the library lives: an empty `apiBase` means this machine (`LocalStorage`),
/// a URL means the storage server (`StorageServer`) (`HttpStorage`).
struct ServerConfig: Codable, Equatable {
    /// The storage server's URL without a trailing slash; empty for local storage.
    var apiBase: String
    /// Sent as a bearer token when the server requires one.
    var token: String

    /// The saved configuration, else one from `PAPERTALK_SERVER_URL` / `PAPERTALK_API_TOKEN`.
    static func load() -> ServerConfig {
        if let saved = SavedJSON.load(ServerConfig.self, key: defaultsKey) { return saved }
        let env = ProcessInfo.processInfo.environment
        return ServerConfig(apiBase: (env["PAPERTALK_SERVER_URL"] ?? "").withoutTrailingSlashes,
                            token: env["PAPERTALK_API_TOKEN"] ?? "")
    }
    /// Write to user defaults (the token included: it isn't a provider key).
    func save() { SavedJSON.save(self, key: Self.defaultsKey) }
    /// User-defaults key of the saved configuration.
    static let defaultsKey = "papertalk.server.json"
}

// MARK: - Settings with an API key

/// Settings that hold an API key: typed (kept in the Keychain only) or named by an environment
/// variable. The LLM's and the speech server's keep it the same way.
protocol KeyedSettings: Codable {
    /// A typed key; never written to user defaults.
    var apiKey: String { get set }
    /// The env var whose value is the key; when set, `apiKey` is ignored.
    var keyEnv: String { get }
    /// The typed key's Keychain account.
    static var typedKeyAccount: String { get }
    /// User-defaults key of the rest.
    static var defaultsKey: String { get }
}

extension KeyedSettings {
    /// The key to send: the env var's value when one is chosen (or the Keychain copy saved for
    /// apps launched from Finder, which don't see shell env), else the typed key.
    func resolvedKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard !keyEnv.isEmpty else { return apiKey }
        if let v = environment[keyEnv], !v.isEmpty { return v }
        return KeychainStore.get(keyEnv) ?? ""
    }

    /// Copy an env-sourced key into the Keychain while the app can see it.
    func saveResolvedKey() {
        guard !keyEnv.isEmpty, let v = ProcessInfo.processInfo.environment[keyEnv], !v.isEmpty else { return }
        KeychainStore.set(v, account: keyEnv)
    }

    /// What goes into user defaults: everything except the key.
    var persisted: Self {
        var copy = self
        copy.apiKey = ""
        return copy
    }

    /// Keep the typed key in the Keychain and the rest in user defaults.
    func save() {
        if apiKey.isEmpty {
            KeychainStore.delete(Self.typedKeyAccount)
        } else {
            KeychainStore.set(apiKey, account: Self.typedKeyAccount)
        }
        SavedJSON.save(persisted, key: Self.defaultsKey)
    }
}

// MARK: - LLM settings for the in-process pipeline (persisted locally)
/// The OpenAI-compatible endpoint that writes episodes. The key is held in memory and the
/// Keychain; user defaults get `persisted`, without it.
struct LLMSettings: KeyedSettings, Equatable {
    /// The API's base URL, e.g. `http://localhost:3000/api`; `/chat/completions` and `/models` go under it.
    var baseUrl: String
    /// A key typed into Settings (empty when it comes from `keyEnv` or there is none).
    var apiKey: String
    /// The model id sent with every request; empty falls back to `llama3.1:70b`.
    var model: String
    /// Optional env var name whose value supplies the API key at request time.
    /// When set, `apiKey` is ignored and the key is never persisted.
    var keyEnv: String

    /// The model requests name when none is chosen.
    static let fallbackModel = "llama3.1:70b"
    /// The model to send.
    var resolvedModel: String { model.isEmpty ? Self.fallbackModel : model }

    /// Keychain account holding a key typed into Settings. It is never written
    /// to user defaults.
    static let typedKeyAccount = "papertalk.llm.apiKey"
    /// User-defaults key of the saved settings (without the key).
    static let defaultsKey = "papertalk.llm.json"

    /// The saved settings, else defaults seeded from the environment (`OPENWEBUI_BASE_URL`,
    /// `LLM_BASE_URL`, `PAPERTALK_MODEL` and the first key variable that is set).
    static func load() -> LLMSettings {
        // Stored value wins; otherwise seed from the environment.
        if var s = SavedJSON.load(LLMSettings.self, key: defaultsKey) {
            if !s.apiKey.isEmpty {
                // Older builds stored the key in plain text: move it to the
                // Keychain and rewrite the defaults entry without it.
                s.save()
            } else {
                s.apiKey = KeychainStore.get(typedKeyAccount) ?? ""
            }
            return s
        }
        let env = ProcessInfo.processInfo.environment
        return LLMSettings(baseUrl: env["OPENWEBUI_BASE_URL"] ?? env["LLM_BASE_URL"] ?? "",
                           apiKey: "",
                           model: env["PAPERTALK_MODEL"] ?? "",
                           keyEnv: candidateKeyEnvs().first ?? "")
    }
}

// MARK: - Where speech is synthesized (persisted locally)

/// Where episode audio is synthesized: Kokoro on this machine, or an OpenAI-compatible speech
/// server. Saved like `LLMSettings`, key in the Keychain only.
struct SpeechSettings: KeyedSettings, Equatable {
    /// `local` is Kokoro on this machine; `remote` a speech server at `baseUrl`.
    enum Engine: String, Codable, CaseIterable { case local, remote }
    /// Where speech is made; this machine unless the user picks a server.
    var engine: Engine = .local
    /// OpenAI-compatible base URL; `/audio/speech` is appended.
    var baseUrl = ""
    /// A typed key. Kept in the Keychain only; never written to user defaults.
    var apiKey = ""
    /// Env var whose value is the key; when set, `apiKey` is ignored (as for the LLM).
    var keyEnv = ""
    /// The server's model id; empty sends `fallbackModel`.
    var model = ""
    /// Speech requests sent at once while voicing a paper (remote only; Kokoro
    /// on this machine always takes one call at a time).
    var parallelRequests = SpeechSettings.defaultParallelRequests

    /// Requests in flight at once on a server, unless the user changes it.
    static let defaultParallelRequests = 4
    /// What the parallel-requests stepper allows.
    static let parallelRange = 1...16

    /// Sent when no model is chosen: OpenAI, Kokoro-FastAPI and Open WebUI all accept it.
    static let fallbackModel = "tts-1"

    /// Clamps `parallelRequests` into `parallelRange`.
    init(engine: Engine = .local, baseUrl: String = "", apiKey: String = "", keyEnv: String = "", model: String = "",
         parallelRequests: Int = SpeechSettings.defaultParallelRequests) {
        self.engine = engine
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.keyEnv = keyEnv
        self.model = model
        self.parallelRequests = Self.clampParallel(parallelRequests)
    }

    // Tolerant: a field added later must not make saved settings unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decodeIfPresent(Engine.self, forKey: .engine)) ?? .local
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        keyEnv = try c.decodeIfPresent(String.self, forKey: .keyEnv) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        parallelRequests = Self.clampParallel((try? c.decodeIfPresent(Int.self, forKey: .parallelRequests)) ?? Self.defaultParallelRequests)
    }

    /// `n` kept within `parallelRange`.
    static func clampParallel(_ n: Int) -> Int { min(max(n, parallelRange.lowerBound), parallelRange.upperBound) }

    /// Keychain account holding a key typed into Settings → Voices.
    static let typedKeyAccount = "papertalk.speech.apiKey"
    /// User-defaults key of the saved settings (without the key).
    static let defaultsKey = "papertalk.speech.json"

    /// The saved settings with the typed key from the Keychain, else the defaults (local Kokoro).
    static func load() -> SpeechSettings {
        guard var s = SavedJSON.load(SpeechSettings.self, key: defaultsKey) else { return SpeechSettings() }
        s.apiKey = KeychainStore.get(typedKeyAccount) ?? ""
        return s
    }
}

// MARK: - Editable LLM prompts (persisted locally)
//
// Every instruction the pipeline sends is editable here. Only the exact JSON
// schemas and the "Name: line" dialogue format stay appended by the pipeline:
// the parsers depend on them, and an edit there would silently break imports.
//
// Templates use {tokens}, replaced at request time (`PromptCatalog` lists
// which ones each prompt gets).
struct PromptSettings: Codable, Equatable {
    /// Metadata extraction: what to pull out of the paper (schema appended).
    var metadata: String
    /// Casting the interviewer and guest (schema appended).
    var cast: String
    /// The paper's mind map: its key concepts and how they connect (schema appended).
    var mindMap: String
    /// Sent when the mind map's three main concepts weren't each broken down.
    var mindMapRetry: String
    /// Which shortlisted concept pairs across papers really relate (schema appended).
    var mindMapConnections: String
    /// System prompt for the outline call.
    var outlineSystem: String
    /// Prose planning rules appended to the outline request (before the schema).
    var outlineRules: String
    /// Sent when the outline reply wasn't valid JSON (schema appended).
    var outlineRepair: String
    /// The {depthGuide} for each depth.
    var depthSummary: String
    var depthInDepth: String
    var depthCustom: String
    /// Host/expert personas shown to the dialogue writer.
    var dialoguePersona: String
    /// "Write for the ear" style rules (shared, plain prose).
    var writeForEar: String
    /// The request for one dialogue segment (format and source appended).
    var segmentRequest: String
    /// Added to the segment request when the episode has a fixed length (summaries).
    var lengthLimit: String
    /// Sent when a segment of a fixed-length episode came out too long (format appended).
    var condense: String
    /// The segment's {position} in the episode.
    var positionOnly: String
    var positionFirst: String
    var positionMiddle: String
    var positionLast: String
    /// First-author persona for technical method monologues.
    var monologuePersona: String
    /// Rules for each monologue block, around its {position}.
    var monologueRules: String
    /// The monologue block's {position}.
    var blockOnly: String
    var blockFirst: String
    var blockMiddle: String
    var blockLast: String
    /// Added to the prompts whose replies are heard or read when an episode isn't in English.
    var outputLanguage: String
    /// System prompt for Ask: chatting about one paper (its details and text appended).
    var ask: String
    /// Slide decks only: describing a slide that is mostly pictures, shown to the LLM as an image.
    var slideDescription: String
    /// Slide decks only: put before the deck's slides, so the prompts written for papers read them as slides.
    var slidesSource: String

    /// Replace each `{token}` in `template`; unknown tokens are left as typed.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    /// The prompts as shipped, also what "Reset to default" restores.
    static let defaults = PromptSettings(
        metadata: """
        You extract bibliographic metadata from a research paper's raw OCR/PDF text.
        - title: the paper's real title (clean, not the filename). If you cannot tell, return "".
        - authors: full author names in order. Empty if unknown.
        - affiliations: institution/department strings, deduplicated. Empty if unknown.
        - doi: the DOI when present (e.g. "10.1016/j.jpdc.2017.07.010"), else "".
        - tags: 2-4 CONSISTENT, broad topical research-areas so related papers group together. Prefer established field categories (e.g. "machine-learning", "nlp", "computer-vision", "algorithms", "databases", "distributed-systems", "security", "bioinformatics", "neuroscience", "quantum-computing"). Multi-word tags are kebab-case with no spaces. NEVER use paper-specific jargon, method acronyms, author names, or narrow low-consumption fragments that won't recur in other papers. Reuse the same category names you'd assign to any similar paper. Never empty unless the text is unusable.
        """,
        cast: """
        You are casting a short research-podcast interview.
        "speakers": exactly two — the interviewer (female by default, propose a realistic first name) and the interviewed scientist, who is one of the paper's real authors; use their given first name and their real gender.
        "authors": every author exactly as listed, each with their most likely gender based on their name.
        """,
        mindMap: """
        You build a mind map (in Italian, a "mappa mentale") of a research paper: its most important concepts and how they connect, for a reader who wants to understand the paper at a glance.
        - summary: 3 to 5 sentences that restate the paper's abstract in plain words: the problem, the approach and what it shows.
        - Exactly three main concepts, with no parent: the PROBLEM the paper tackles (branch "problem"), the METHOD or approach it takes (branch "method"), and the DEMONSTRATION, the experiments and evidence that show it works (branch "evidence").
        - Break each main concept into 2 to 5 more specific concepts (their parent is its id), and break those down further where it helps. Aim for 12 to 30 concepts in all.
        - label: the concept's name, at most 4 words. A name, never a sentence.
        - description: 2 to 4 sentences on what the concept means in this paper and why it matters, so a reader new to the topic can follow.
        - core: 1 to 2 sentences with its key feature, finding or number, including enough context to make sense on its own.
        - links: a few connections between concepts on different branches (for example, a method step that answers part of the problem, or a result that validates a step), each with a label of 1 to 3 words.
        - Use only what the paper states.
        """,
        mindMapRetry: "Your mind map must break each of the three main concepts (problem, method, evidence) into at least two more specific concepts. Return the whole mind map again.",
        mindMapConnections: """
        You connect a research paper's concepts to concepts from other papers in the same library. Each numbered pair below joins a concept of THIS PAPER to a concept of another paper; they were picked only because they share words, so many are not really related.
        - Keep a pair only when the two concepts are genuinely connected: the same technique, dataset, metric or problem, one builds on or extends the other, they compete, or one contradicts the other.
        - label: how the concept of this paper relates to the other one, in 1 to 3 words (for example "same dataset", "extends", "alternative to").
        - Leave out every pair that only shares generic words. Returning no pairs is fine.
        """,
        outlineSystem: "You are an expert science-podcast editor. You respond with strict JSON only.",
        outlineRules: """
        You are planning a two-speaker podcast episode about a research paper. First break the paper into an ordered, numbered SECTION INDEX of its major sections (Abstract, Introduction, Related Work, Method/Model/Approach, Experiments/Evaluation, Results, Discussion, Conclusion, ... Keep the paper's own titles where clear). Then design an OUTLINE of listening segments covering the whole paper.

        OUTLINE & SEGMENTATION RULES:
        - Target total length ≈ {minutes} minutes.
        - Use no less than {minSeg} and no more than {maxSeg} segments.
        - In an IN-DEPTH episode, the technical heart of the paper (Method / Model / Approach / Algorithm sections) MUST be its own segment(s) with "monologue": true — these are delivered as a long, faithful, full-length spoken walkthrough. For any other depth (e.g. SUMMARY) set "monologue": false on every segment.
        - Every section in the section index must be covered by at least one segment (map each segment to the 1-based indices of the sections it covers via "sections").
        - Give each segment: a clear spoken goal (e.g. "explain the key idea of attention"), the key_points that must be hit, and a "weight" (0–1, sums used to split the ~{plannedWords} planned words so longer/more technical parts get more airtime).
        - {depthGuide}
        """,
        outlineRepair: "Your previous reply was not valid JSON for my schema.",
        depthSummary: "DEPTH: SUMMARY. Overview-style episode for a general audience. Summarise method and results at a high level; no section is read verbatim.",
        depthInDepth: "DEPTH: IN-DEPTH. Cover methods and results fully and technically, so a student could re-derive the work.",
        depthCustom: "USER-REQUESTED DEPTH:\n{note}",
        dialoguePersona: """
        You are a scriptwriter writing a faithful, detailed, two-speaker spoken podcast episode from a scientific paper. {host} is the HOST (sharp, technical, asks the questions a smart listener would, asks for intuition, signposts transitions). {expert} is the EXPERT, the paper's first author (carries the technical content, exact figures, never condescending).
        """,
        writeForEar: """
        WRITE FOR THE EAR — the text will be read aloud by a text-to-speech engine:
        - Plain sentences only. No markdown, bullets, headings, emojis, stage directions, or sound effects.
        - No citation markers like [12] or (Smith et al., 2020); say "earlier work by Smith and colleagues" if needed.
        - Verbalise math: "x squared", "the sum over all tokens of the log probability"; explain what an equation means rather than reading long formulas symbol by symbol.
        - Say numbers as they are spoken: "about ninety-two point four percent", "ten to the minus three".
        - Expand abbreviations the first time they appear.
        - Mostly 1–5 sentences per turn; vary rhythm with occasional short reactions ("Right.", "Wait, so...").
        - Vary how turns begin. Don't open turns, and never a segment, with a filler like "So", "Okay" or "Well".
        - Stay faithful to the source. Never invent results, numbers or claims.
        """,
        segmentRequest: """
        SEGMENT {segmentNumber} of {segmentCount} — Title: "{segmentTitle}"
        GOAL: {goal}
        MUST COVER (key points):
        {keyPoints}

        TARGET LENGTH: about {targetWords} words. Write a full, detailed conversation — do not rush or truncate.

        OTHER SEGMENTS IN THIS EPISODE (do not repeat them):
        {otherSegments}

        ALREADY COVERED EARLIER (do not repeat these points):
        {covered}

        RECENT TURNS FROM THE EPISODE SO FAR (match their tone and continue naturally; do not re-say them):
        {recentTurns}

        POSITION IN THE EPISODE:
        {position}
        """,
        lengthLimit: "HARD LIMIT: at most {maxWords} words for this segment. The episode has a fixed length, so cover the goal briefly and stop; leave out side points rather than run over.",
        condense: "This dialogue segment is too long for the episode. Rewrite it in about {targetWords} words: keep the same speakers, the key facts and numbers, and how it ends; drop repetition, small talk and side points.",
        positionOnly: "This is the ONLY segment of the episode. {host} opens by introducing the paper, its authors and the topic, in a first line that makes sense with nothing before it (no \"So\", \"And\" or \"Okay\" to start), then you have a complete conversation from start to finish, landing a satisfying ending.",
        positionFirst: "This is the FIRST segment. {host} starts the episode by introducing the paper, its authors and the topic, in a first line that makes sense with nothing before it (no \"So\", \"And\" or \"Okay\" to start). Leave room for the later segments; do not jump to conclusions.",
        positionMiddle: "This is a MIDDLE segment. {host} briefly signals this part's goal in a fresh opening line (not \"So…\"), then keep going. Do not reintroduce the paper or wrap up the episode.",
        positionLast: "This is the LAST segment. Open with a fresh line (not \"So…\"), build on what was covered and move the conversation to a satisfying conclusion and wrap-up.",
        monologuePersona: """
        You are {expert}, the paper's first author, explaining the method aloud to a listener who wants to re-derive it. Build a SINGLE continuous monologue that reproduces the paper's method FAITHFULLY and at FULL length — do not summarise, condense, or drop any step, definition, parameter, equation, assumption, dataset, baseline, or number. The source is raw OCR/PDF text full of extraction artifacts (broken hyphenated words, mangled symbols and equations): repair those so it reads as clean, natural spoken prose, and verbalise every equation in words. Keep the paper's own framing and every number exactly as stated. Never add content the source does not state.
        """,
        monologueRules: "WRITE FOR THE EAR: plain sentences, no markdown, no headings, no stage directions.\n{position}",
        blockOnly: "This is the only block.",
        blockFirst: "This is block 1 (the first part).",
        blockMiddle: "This block continues the monologue; keep the same voice and flow.",
        blockLast: "This is the final block.",
        outputLanguage: """
        LANGUAGE: Write everything the listener hears or reads in {language}: the dialogue, the narration, segment titles, goals and key points, the summary, concept labels and descriptions. The paper and these instructions may be in English; write in {language} anyway, using the usual {language} terms for technical concepts. Keep the speaker names, the reply format, JSON keys and fixed values (such as "problem", "method" and "evidence") exactly as specified.
        """,
        ask: """
        You are a research assistant chatting with a reader about one research paper. Its details and its full text, extracted from the PDF, follow below.
        - Answer from the paper. Say where in it the answer comes from (a section, figure, table or equation) when you can.
        - When the paper doesn't say, say so plainly, then add general background only if it helps, marked as not from the paper.
        - The text comes from PDF extraction and may have broken words and mangled equations: read through them, and write equations in plain notation.
        - Be concise and specific. Answer in the language of the question.
        """,
        slideDescription: """
        You are shown one slide of a presentation, as an image, with any text extracted from it.
        Describe what the slide shows so that someone who can't see it learns everything it conveys: diagrams, charts (axes, trends, the numbers that matter), tables, photos, equations and how the parts relate.
        - Say what the slide means, not how it looks: skip colours, fonts and layout unless they carry meaning.
        - Don't repeat the extracted text word for word; use it to read the picture.
        - Plain prose, no headings or lists, at most 150 words. If the slide shows nothing of substance (a title or a logo), say so in one sentence.
        """,
        slidesSource: """
        This source is a slide deck (a presentation), not a paper: wherever the instructions say "paper", read "presentation". Each slide's text follows, numbered, with a description of what its pictures show in brackets. Slides are terse: explain the ideas they point to, but don't invent results the slides don't show.
        """
    )
}

extension PromptSettings {
    /// Saved prompts from older builds lack the newer fields: those take their
    /// defaults, so a user's edits to the others survive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        func v(_ key: CodingKeys, _ fallback: String) throws -> String {
            try c.decodeIfPresent(String.self, forKey: key) ?? fallback
        }
        self.init(metadata: try v(.metadata, d.metadata), cast: try v(.cast, d.cast),
                  mindMap: try v(.mindMap, d.mindMap), mindMapRetry: try v(.mindMapRetry, d.mindMapRetry),
                  mindMapConnections: try v(.mindMapConnections, d.mindMapConnections),
                  outlineSystem: try v(.outlineSystem, d.outlineSystem), outlineRules: try v(.outlineRules, d.outlineRules),
                  outlineRepair: try v(.outlineRepair, d.outlineRepair),
                  depthSummary: try v(.depthSummary, d.depthSummary), depthInDepth: try v(.depthInDepth, d.depthInDepth),
                  depthCustom: try v(.depthCustom, d.depthCustom),
                  dialoguePersona: try v(.dialoguePersona, d.dialoguePersona), writeForEar: try v(.writeForEar, d.writeForEar),
                  segmentRequest: try v(.segmentRequest, d.segmentRequest),
                  lengthLimit: try v(.lengthLimit, d.lengthLimit), condense: try v(.condense, d.condense),
                  positionOnly: try v(.positionOnly, d.positionOnly), positionFirst: try v(.positionFirst, d.positionFirst),
                  positionMiddle: try v(.positionMiddle, d.positionMiddle), positionLast: try v(.positionLast, d.positionLast),
                  monologuePersona: try v(.monologuePersona, d.monologuePersona),
                  monologueRules: try v(.monologueRules, d.monologueRules),
                  blockOnly: try v(.blockOnly, d.blockOnly), blockFirst: try v(.blockFirst, d.blockFirst),
                  blockMiddle: try v(.blockMiddle, d.blockMiddle), blockLast: try v(.blockLast, d.blockLast),
                  outputLanguage: try v(.outputLanguage, d.outputLanguage), ask: try v(.ask, d.ask),
                  slideDescription: try v(.slideDescription, d.slideDescription),
                  slidesSource: try v(.slidesSource, d.slidesSource))
    }
    /// The saved prompts, else the defaults.
    static func load() -> PromptSettings { SavedJSON.load(PromptSettings.self, key: defaultsKey) ?? defaults }
    /// Write to user defaults (they hold no secrets).
    func save() { SavedJSON.save(self, key: Self.defaultsKey) }
    /// User-defaults key of the saved prompts.
    static var defaultsKey: String { "papertalk.prompts.json" }
}

/// Named instructions for the Custom depth, picked from the import sheet.
struct CustomDepthPresets: Codable {
    /// One preset: a unique name and the instructions sent as the depth guide.
    struct Entry: Codable, Identifiable, Equatable {
        let name: String
        let text: String
        var id: String { name }
    }
    /// In the order they were added; names are unique (`PresetsForm.clean`).
    var entries: [Entry]

    /// The saved presets, else none.
    static func load() -> CustomDepthPresets {
        SavedJSON.load(CustomDepthPresets.self, key: defaultsKey) ?? CustomDepthPresets(entries: [])
    }
    /// Write to user defaults.
    func save() { SavedJSON.save(self, key: Self.defaultsKey) }
    /// User-defaults key of the saved presets.
    static let defaultsKey = "papertalk.customDepths.json"
}

/// The environment variables read as API keys, in order of preference.
let apiKeyEnvNames = ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY"]

/// Names of environment variables that (when set) look like current API keys,
/// offered in the settings sheet as selectable key sources.
func candidateKeyEnvs() -> [String] {
    let env = ProcessInfo.processInfo.environment
    return apiKeyEnvNames.filter { !(env[$0] ?? "").isEmpty }
}
