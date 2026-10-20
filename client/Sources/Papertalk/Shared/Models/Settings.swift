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
    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif

// MARK: - Server configuration (persisted in the app)
struct ServerConfig: Codable, Equatable {
    var apiBase: String
    var token: String

    static func load() -> ServerConfig {
        let defaults = UserDefaults.standard
        let envBase = ProcessInfo.processInfo.environment["PAPERTALK_SERVER_URL"] ?? ""
        let envToken = ProcessInfo.processInfo.environment["PAPERTALK_API_TOKEN"] ?? ""
        if let raw = defaults.string(forKey: "papertalk.server.json"),
           let data = raw.data(using: .utf8),
           let c = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            return c
        }
        return ServerConfig(apiBase: envBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression), token: envToken)
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "papertalk.server.json")
        }
    }
}

// MARK: - LLM settings for the in-process pipeline (persisted locally)
struct LLMSettings: Codable, Equatable {
    var baseUrl: String
    var apiKey: String
    var model: String
    /// Optional env var name whose value supplies the API key at request time.
    /// When set, `apiKey` is ignored and the key is never persisted.
    var keyEnv: String

    /// The effective API key: env var wins when one is selected; otherwise the
    /// keychain copy captured at save time (GUI-launched apps don't see shell env).
    func resolvedKey() -> String {
        if !keyEnv.isEmpty {
            if let v = ProcessInfo.processInfo.environment[keyEnv], !v.isEmpty { return v }
            if let v = KeychainStore.get(keyEnv), !v.isEmpty { return v }
            return ""
        }
        return apiKey
    }

    /// Persist the env-sourced key into the keychain (no-op when key comes from a
    /// shell env var the app can actually see).
    func saveResolvedKey() {
        guard !keyEnv.isEmpty,
              let v = ProcessInfo.processInfo.environment[keyEnv], !v.isEmpty else { return }
        KeychainStore.set(v, account: keyEnv)
    }

    /// Keychain account holding a key typed into Settings. It is never written
    /// to user defaults.
    static let typedKeyAccount = "papertalk.llm.apiKey"

    static func load() -> LLMSettings {
        // Stored value wins; otherwise seed from the environment.
        if let raw = UserDefaults.standard.string(forKey: "papertalk.llm.json"),
           let data = raw.data(using: .utf8),
           var s = try? JSONDecoder().decode(LLMSettings.self, from: data) {
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
        let keyEnv = firstSet(env, ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY"])
        return LLMSettings(baseUrl: env["OPENWEBUI_BASE_URL"] ?? env["LLM_BASE_URL"] ?? "",
                           apiKey: "",
                           model: env["PAPERTALK_MODEL"] ?? "",
                           keyEnv: keyEnv)
    }
    /// What goes into user defaults: everything except the key, which lives
    /// in the Keychain only.
    var persisted: LLMSettings {
        var copy = self
        copy.apiKey = ""
        return copy
    }

    func save() {
        if apiKey.isEmpty {
            KeychainStore.delete(Self.typedKeyAccount)
        } else {
            KeychainStore.set(apiKey, account: Self.typedKeyAccount)
        }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "papertalk.llm.json")
        }
    }
}

// MARK: - Where speech is synthesized (persisted locally)

struct SpeechSettings: Codable, Equatable {
    enum Engine: String, Codable, CaseIterable { case local, remote }
    var engine: Engine = .local
    /// OpenAI-compatible base URL; `/audio/speech` is appended.
    var baseUrl = ""
    /// A typed key. Kept in the Keychain only; never written to user defaults.
    var apiKey = ""
    /// Env var whose value is the key; when set, `apiKey` is ignored (as for the LLM).
    var keyEnv = ""
    var model = ""
    /// Speech requests sent at once while voicing a paper (remote only; Kokoro
    /// on this machine always takes one call at a time).
    var parallelRequests = SpeechSettings.defaultParallelRequests

    static let defaultParallelRequests = 4
    static let parallelRange = 1...16

    /// Sent when no model is chosen: OpenAI, Kokoro-FastAPI and Open WebUI all accept it.
    static let fallbackModel = "tts-1"

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

    /// The key to send: the env var's value when one is chosen (or the Keychain
    /// copy saved for apps launched from Finder, which don't see shell env),
    /// else the typed key.
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

    static func clampParallel(_ n: Int) -> Int { min(max(n, parallelRange.lowerBound), parallelRange.upperBound) }

    /// The backend these settings ask for. The one place a backend is chosen.
    func makeBackend() -> any SpeechBackend {
        switch engine {
        case .local: return LocalSpeechBackend()
        case .remote: return RemoteSpeechBackend(settings: self)
        }
    }

    static let typedKeyAccount = "papertalk.speech.apiKey"
    static let defaultsKey = "papertalk.speech.json"

    static func load() -> SpeechSettings {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let data = raw.data(using: .utf8),
              var s = try? JSONDecoder().decode(SpeechSettings.self, from: data) else { return SpeechSettings() }
        s.apiKey = KeychainStore.get(typedKeyAccount) ?? ""
        return s
    }

    /// What goes into user defaults: everything except the key.
    var persisted: SpeechSettings {
        var copy = self
        copy.apiKey = ""
        return copy
    }

    func save() {
        if apiKey.isEmpty {
            KeychainStore.delete(Self.typedKeyAccount)
        } else {
            KeychainStore.set(apiKey, account: Self.typedKeyAccount)
        }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: Self.defaultsKey)
        }
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

    /// Replace each `{token}` in `template`; unknown tokens are left as typed.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

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
        - Exactly three main concepts, with no parent: the PROBLEM the paper tackles (branch "problem"), the METHOD or approach it takes (branch "method"), and the DEMONSTRATION, the experiments and evidence that show it works (branch "evidence").
        - Break each main concept into 2 to 5 more specific concepts (their parent is its id), and break those down further where it helps. Aim for 12 to 30 concepts in all.
        - label: the concept's name, at most 4 words. A name, never a sentence.
        - description: 2 to 4 sentences on what the concept means in this paper and why it matters, so a reader new to the topic can follow.
        - core: 1 to 2 sentences with its key feature, finding or number, including enough context to make sense on its own.
        - links: a few connections between concepts on different branches (for example, a method step that answers part of the problem, or a result that validates a step), each with a label of 1 to 3 words.
        - Use only what the paper states.
        """,
        mindMapRetry: "Your mind map must break each of the three main concepts (problem, method, evidence) into at least two more specific concepts. Return the whole mind map again.",
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
        positionOnly: "This is the ONLY segment of the episode. {host} opens by introducing the paper, its authors and the topic, then you have a complete conversation from start to finish, landing a satisfying ending.",
        positionFirst: "This is the FIRST segment. {host} starts the episode by introducing the paper, its authors and the topic. Leave room for the later segments; do not jump to conclusions.",
        positionMiddle: "This is a MIDDLE segment. {host} briefly signals this part's goal, then keep going. Do not reintroduce the paper or wrap up the episode.",
        positionLast: "This is the LAST segment. Build on what was covered and move the conversation to a satisfying conclusion and wrap-up.",
        monologuePersona: """
        You are {expert}, the paper's first author, explaining the method aloud to a listener who wants to re-derive it. Build a SINGLE continuous monologue that reproduces the paper's method FAITHFULLY and at FULL length — do not summarise, condense, or drop any step, definition, parameter, equation, assumption, dataset, baseline, or number. The source is raw OCR/PDF text full of extraction artifacts (broken hyphenated words, mangled symbols and equations): repair those so it reads as clean, natural spoken prose, and verbalise every equation in words. Keep the paper's own framing and every number exactly as stated. Never add content the source does not state.
        """,
        monologueRules: "WRITE FOR THE EAR: plain sentences, no markdown, no headings, no stage directions.\n{position}",
        blockOnly: "This is the only block.",
        blockFirst: "This is block 1 (the first part).",
        blockMiddle: "This block continues the monologue; keep the same voice and flow.",
        blockLast: "This is the final block."
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
                  blockMiddle: try v(.blockMiddle, d.blockMiddle), blockLast: try v(.blockLast, d.blockLast))
    }
    static func load() -> PromptSettings {
        if let raw = UserDefaults.standard.string(forKey: "papertalk.prompts.json"),
           let data = raw.data(using: .utf8),
           let s = try? JSONDecoder().decode(PromptSettings.self, from: data) {
            return s
        }
        return defaults
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "papertalk.prompts.json")
        }
    }
}

struct CustomDepthPresets: Codable {
    struct Entry: Codable, Identifiable, Equatable {
        let name: String
        let text: String
        var id: String { name }
    }
    var entries: [Entry]

    static func load() -> CustomDepthPresets {
        if let raw = UserDefaults.standard.string(forKey: "papertalk.customDepths.json"),
           let data = raw.data(using: .utf8),
           let p = try? JSONDecoder().decode(CustomDepthPresets.self, from: data) {
            return p
        }
        return CustomDepthPresets(entries: [])
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "papertalk.customDepths.json")
        }
    }
}

/// Names of environment variables that (when set) look like current API keys,
/// offered in the settings sheet as selectable key sources.
func candidateKeyEnvs() -> [String] {
    let env = ProcessInfo.processInfo.environment
    return ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY"]
        .filter { !(env[$0] ?? "").isEmpty }
}

private func firstSet(_ env: [String: String], _ keys: [String]) -> String {
    keys.first { !(env[$0] ?? "").isEmpty } ?? ""
}