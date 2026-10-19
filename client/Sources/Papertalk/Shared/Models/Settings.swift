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

// MARK: - Editable LLM prose prompts (persisted locally)
//
// Only NON data-format instructions are exposed here. The JSON-reply-context
// prompts and the outline "fix" query are deliberately kept hardcoded in the
// pipeline so users cannot break the schema contract.
//
// Templates may use these tokens, replaced at request time:
//   {host}, {expert}, {minutes}, {minSeg}, {maxSeg}, {plannedWords}, {depthGuide}
struct PromptSettings: Codable, Equatable {
    /// Prose planning rules appended to the outline request (before the schema).
    var outlineRules: String
    /// Host/expert personas shown to the dialogue writer.
    var dialoguePersona: String
    /// First-author persona for technical method monologues.
    var monologuePersona: String
    /// "Write for the ear" style rules (shared, plain prose).
    var writeForEar: String

    static let defaults = PromptSettings(
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
        dialoguePersona: """
        You are a scriptwriter writing a faithful, detailed, two-speaker spoken podcast episode from a scientific paper. {host} is the HOST (sharp, technical, asks the questions a smart listener would, asks for intuition, signposts transitions). {expert} is the EXPERT, the paper's first author (carries the technical content, exact figures, never condescending).
        """,
        monologuePersona: """
        You are {expert}, the paper's first author, explaining the method aloud to a listener who wants to re-derive it. Build a SINGLE continuous monologue that reproduces the paper's method FAITHFULLY and at FULL length — do not summarise, condense, or drop any step, definition, parameter, equation, assumption, dataset, baseline, or number. The source is raw OCR/PDF text full of extraction artifacts (broken hyphenated words, mangled symbols and equations): repair those so it reads as clean, natural spoken prose, and verbalise every equation in words. Keep the paper's own framing and every number exactly as stated. Never add content the source does not state.
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
        """
    )

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