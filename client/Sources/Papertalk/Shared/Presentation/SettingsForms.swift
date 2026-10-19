import Foundation

/// Where the LLM API key comes from.
enum LLMKeySource: String, CaseIterable, Identifiable {
    case none = "No key"
    case env = "From environment"
    case manual = "Type a key"
    var id: String { rawValue }
}

/// The LLM settings as edited in Settings and in the setup wizard.
struct LLMSettingsForm: Equatable {
    var baseUrl = ""
    var model = ""
    var keySource: LLMKeySource = .none
    var selectedEnv = ""
    var manualKey = ""
    /// Key environment variables that are set (`candidateKeyEnvs()`).
    let setEnvVars: [String]

    init(_ s: LLMSettings, setEnvVars: [String] = candidateKeyEnvs()) {
        self.setEnvVars = setEnvVars
        baseUrl = s.baseUrl
        model = s.model
        selectedEnv = s.keyEnv
        if !s.keyEnv.isEmpty { keySource = .env }
        else if !s.apiKey.isEmpty { keySource = .manual; manualKey = s.apiKey }
    }

    /// Variables offered in the picker: the set ones, plus the saved choice
    /// even if it isn't set right now (so it isn't silently dropped).
    var envOptions: [String] {
        var opts = setEnvVars
        if !selectedEnv.isEmpty && !opts.contains(selectedEnv) { opts.insert(selectedEnv, at: 0) }
        return opts
    }

    /// Call when the key source changes: picking "From environment" selects
    /// the first available variable if none is chosen yet.
    mutating func keySourceChanged() {
        if keySource == .env, selectedEnv.isEmpty { selectedEnv = envOptions.first ?? "" }
    }

    private var trimmedBaseURL: String { baseUrl.trimmingCharacters(in: .whitespaces) }

    var canFetchModels: Bool { !trimmedBaseURL.isEmpty }

    /// The key to use right now (for listing models / testing the connection).
    func effectiveKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        switch keySource {
        case .env: return environment[selectedEnv] ?? ""
        case .manual: return manualKey.trimmingCharacters(in: .whitespaces)
        case .none: return ""
        }
    }

    /// The settings to save. Only the chosen key source's value is kept.
    var settings: LLMSettings {
        LLMSettings(baseUrl: trimmedBaseURL,
                    apiKey: keySource == .manual ? manualKey.trimmingCharacters(in: .whitespaces) : "",
                    model: model.trimmingCharacters(in: .whitespaces),
                    keyEnv: keySource == .env ? selectedEnv : "")
    }

    /// After listing the server's models: keep the chosen model if it's
    /// offered, else pick the first. Returns a message when the list is empty.
    mutating func applyModels(_ ids: [String]) -> String? {
        if !ids.contains(model) { model = ids.first ?? model }
        return ids.isEmpty ? "No models returned by /models" : nil
    }

    /// Ask the endpoint for its models.
    func fetchModels() async throws -> [String] {
        try await LocalPipeline(baseUrl: trimmedBaseURL, apiKey: effectiveKey(), model: model).listModels()
    }
}

/// The storage server settings, in Settings and in the setup wizard.
struct ServerSettingsForm: Equatable {
    enum Mode: String { case local, remote }
    var mode: Mode
    var apiBase: String
    var token: String

    init(_ c: ServerConfig) {
        apiBase = c.apiBase
        token = c.token
        mode = c.apiBase.isEmpty ? .local : .remote
    }

    /// The config to save. "On this Mac" means no server URL; a URL loses
    /// surrounding spaces and trailing slashes.
    var config: ServerConfig {
        guard mode == .remote else { return ServerConfig(apiBase: "", token: token) }
        let url = apiBase.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return ServerConfig(apiBase: url, token: token)
    }

    /// The Settings page has no local/remote switch: an empty URL means this Mac.
    var configFromURL: ServerConfig {
        var f = self
        f.mode = apiBase.trimmingCharacters(in: .whitespaces).isEmpty ? .local : .remote
        return f.config
    }

    /// Review line in the setup wizard.
    var summary: String {
        guard mode == .remote else { return "This Mac" }
        let url = apiBase.trimmingCharacters(in: .whitespaces)
        return url.isEmpty ? "Remote (no URL)" : url
    }
}

/// Wording for the single-page settings sheet (Linux), which doubles as
/// first-run setup.
enum SettingsSheetPresentation {
    static func title(isSetup: Bool) -> String { isSetup ? "Welcome to Papertalk" : "Settings" }
    static func saveTitle(isSetup: Bool) -> String { isSetup ? "Finish setup" : "Save" }
    static let intro = "Papertalk writes each episode with an OpenAI-compatible LLM, then synthesizes the voices on \(Device.this) with Kokoro."
    static let noEnvVars = "No API-key environment variables are set. Add one (e.g. OPENWEBUI_API_KEY) and reopen this window."
    static let serverHelp = "Optional storage_server.py for sharing the library. Leave empty to keep papers on \(Device.this)."
}

/// The first-run setup wizard's steps.
enum SetupStep: Equatable {
    case storage, llm, voices, review

    var next: SetupStep? {
        switch self {
        case .storage: return .llm
        case .llm: return .voices
        case .voices: return .review
        case .review: return nil
        }
    }

    var previous: SetupStep? {
        switch self {
        case .storage: return nil
        case .llm: return .storage
        case .voices: return .llm
        case .review: return .voices
        }
    }

    /// "Skip setup" is offered until the review step.
    var canSkip: Bool { self != .review }

    var nextTitle: String {
        switch self {
        case .storage, .llm: return "Continue"
        case .voices: return "Review"
        case .review: return "Finish"
        }
    }

    /// Review lines for the LLM part.
    static func llmSummary(_ s: LLMSettings) -> [(label: String, value: String)] {
        guard !s.baseUrl.isEmpty else { return [("LLM endpoint", "Not configured (read-through)")] }
        return [("LLM endpoint", s.baseUrl), ("Model", s.model.isEmpty ? "—" : s.model)]
    }
}

/// Custom-depth presets as edited in Settings.
enum PresetsForm {
    /// What gets saved: trimmed, without empty names or texts, first of each name wins.
    static func clean(_ entries: [(name: String, text: String)]) -> [CustomDepthPresets.Entry] {
        var seen = Set<String>()
        var out: [CustomDepthPresets.Entry] = []
        for e in entries {
            let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !text.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(.init(name: name, text: text))
        }
        return out
    }
}

/// Settings → Clear Data.
enum ClearDataPresentation {
    static func voiceModels(bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Not downloaded"
    }

    static func deleteVoiceModelsHelp(conversionRunning: Bool) -> String {
        conversionRunning ? "Wait for conversions to finish" : ""
    }

    static func canDeleteVoiceModels(bytes: Int64, conversionRunning: Bool) -> Bool {
        bytes > 0 && !conversionRunning
    }
}
