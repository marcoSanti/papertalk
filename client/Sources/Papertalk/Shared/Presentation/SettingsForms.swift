// Settings forms shared by the Settings window and the first-run setup: the API key source, the
// LLM and storage server fields, setup's steps, custom-depth presets, the Clear Data page and
// the library folder.

import Foundation

/// Where an API key (the LLM's or the speech server's) comes from.
enum LLMKeySource: String, CaseIterable, Identifiable {
    case none = "No key"
    case env = "From environment"
    case manual = "Type a key"
    var id: String { rawValue }

    /// The segmented picker's title.
    var label: String {
        switch self {
        case .none: return L("No key")
        case .env: return L("From environment")
        case .manual: return L("Type a key")
        }
    }

    /// The source a saved key implies: an env var name wins, then a typed key.
    init(keyEnv: String, apiKey: String) {
        self = !keyEnv.isEmpty ? .env : !apiKey.isEmpty ? .manual : .none
    }
}

/// A form with an API key that is typed, read from an environment variable, or
/// absent. `KeySourceFields` edits any of them the same way.
protocol KeySourceEditing {
    /// Where the key comes from.
    var keySource: LLMKeySource { get set }
    /// The chosen environment variable, when `keySource` is `.env`.
    var selectedEnv: String { get set }
    /// The typed key, when `keySource` is `.manual`.
    var manualKey: String { get set }
    /// Key environment variables that are set (`candidateKeyEnvs()`).
    var setEnvVars: [String] { get }
}

extension KeySourceEditing {
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

    /// The key to use right now (for listing models / testing the connection).
    func effectiveKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        switch keySource {
        case .env: return environment[selectedEnv] ?? ""
        case .manual: return manualKey.trimmingCharacters(in: .whitespaces)
        case .none: return ""
        }
    }

    /// The saved pair (typed key, env var name): only the chosen source's value is kept.
    var keyFields: (apiKey: String, keyEnv: String) {
        (keySource == .manual ? manualKey.trimmingCharacters(in: .whitespaces) : "",
         keySource == .env ? selectedEnv : "")
    }
}

/// The LLM settings as edited in Settings and in the setup wizard.
struct LLMSettingsForm: Equatable, KeySourceEditing {
    /// The endpoint as typed (trimmed when saved).
    var baseUrl = ""
    /// Typed, or picked from the endpoint's `/models`.
    var model = ""
    /// Where the API key comes from.
    var keySource: LLMKeySource = .none
    /// Used when `keySource` is `.env`.
    var selectedEnv = ""
    /// Used when `keySource` is `.manual`.
    var manualKey = ""
    /// Key environment variables that are set (`candidateKeyEnvs()`).
    let setEnvVars: [String]

    /// The form showing the saved settings `s`.
    init(_ s: LLMSettings, setEnvVars: [String] = candidateKeyEnvs()) {
        self.setEnvVars = setEnvVars
        baseUrl = s.baseUrl
        model = s.model
        selectedEnv = s.keyEnv
        keySource = LLMKeySource(keyEnv: s.keyEnv, apiKey: s.apiKey)
        if keySource == .manual { manualKey = s.apiKey }
    }

    private var trimmedBaseURL: String { baseUrl.trimmingCharacters(in: .whitespaces) }

    /// Models can be listed once there's a URL.
    var canFetchModels: Bool { !trimmedBaseURL.isEmpty }

    /// The settings to save. Only the chosen key source's value is kept.
    var settings: LLMSettings {
        LLMSettings(baseUrl: trimmedBaseURL, apiKey: keyFields.apiKey,
                    model: model.trimmingCharacters(in: .whitespaces), keyEnv: keyFields.keyEnv)
    }

    /// After listing the server's models: keep the chosen model if it's
    /// offered, else pick the first. Returns a message when the list is empty.
    mutating func applyModels(_ ids: [String]) -> String? {
        if !ids.contains(model) { model = ids.first ?? model }
        return ids.isEmpty ? L("No models returned by /models") : nil
    }

    /// Ask the endpoint for its models.
    func fetchModels() async throws -> [String] {
        try await LocalPipeline(baseUrl: trimmedBaseURL, apiKey: effectiveKey(), model: model).listModels()
    }
}

/// The storage server settings, in Settings and in the setup wizard.
struct ServerSettingsForm: Equatable {
    /// Local: papers on this machine; remote: on `storage_server.py`.
    enum Mode: String { case local, remote }
    /// Chosen in setup; Settings derives it from the URL (`configFromURL`).
    var mode: Mode
    /// The server URL as typed.
    var apiBase: String
    /// The server's bearer token, if it needs one.
    var token: String

    /// The form showing the saved configuration.
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
        guard mode == .remote else { return Device.thisTitle }
        let url = apiBase.trimmingCharacters(in: .whitespaces)
        return url.isEmpty ? L("Remote (no URL)") : url
    }
}

/// Wording for the single-page settings sheet (Linux), which doubles as
/// first-run setup.
enum SettingsSheetPresentation {
    /// The sheet's title: setup on first launch, else Settings.
    static func title(isSetup: Bool) -> String { isSetup ? L("Welcome to Papertalk") : L("Settings") }
    /// The confirm button.
    static func saveTitle(isSetup: Bool) -> String { isSetup ? L("Finish setup") : L("Save") }
    /// What the app needs, under the title.
    static var intro: String { L("Papertalk writes each episode with an OpenAI-compatible LLM, then synthesizes the voices on {0} with Kokoro.", Device.this) }
    /// When "From environment" is chosen but no key variable is set.
    static var noEnvVars: String { L("No API-key environment variables are set. Add one (e.g. OPENWEBUI_API_KEY) and reopen this window.") }
    /// Under the storage server fields.
    static var serverHelp: String { L("Optional storage_server.py for sharing the library. Leave empty to keep papers on {0}.", Device.this) }
}

/// The first-run setup wizard's steps.
enum SetupStep: Equatable {
    case storage, llm, voices, review

    /// The step after this one; nil on the last.
    var next: SetupStep? {
        switch self {
        case .storage: return .llm
        case .llm: return .voices
        case .voices: return .review
        case .review: return nil
        }
    }

    /// The step before this one; nil on the first.
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

    /// The forward button's title on this step.
    var nextTitle: String {
        switch self {
        case .storage, .llm: return L("Continue")
        case .voices: return L("Review")
        case .review: return L("Finish")
        }
    }

    /// Review lines for the LLM part.
    static func llmSummary(_ s: LLMSettings) -> [(label: String, value: String)] {
        guard !s.baseUrl.isEmpty else { return [(L("LLM endpoint"), L("Not configured (read-through)"))] }
        return [(L("LLM endpoint"), s.baseUrl), (L("Model"), s.model.isEmpty ? "—" : s.model)]
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
    /// The models' size on disk, or that they aren't downloaded.
    static func voiceModels(bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : L("Not downloaded")
    }

    /// Why Delete is disabled, if it is.
    static func deleteVoiceModelsHelp(conversionRunning: Bool) -> String {
        conversionRunning ? L("Wait for conversions to finish") : ""
    }

    /// Deleting needs models on disk and no conversion using them.
    static func canDeleteVoiceModels(bytes: Int64, conversionRunning: Bool) -> Bool {
        bytes > 0 && !conversionRunning
    }
}

/// The General page's library folder section: its wording and when the folder can change.
enum LibraryFolderPresentation {
    /// Moving the library needs it on this Mac and no conversion writing into it.
    static func canChange(isStandalone: Bool, converting: Bool) -> Bool { isStandalone && !converting }

    /// The line under the buttons: why it's disabled, else what a change does.
    static func note(isStandalone: Bool, converting: Bool) -> String {
        if !isStandalone { return L("The library is on the storage server; the folder applies only without one.") }
        if converting { return L("Wait for the conversion to finish to move the library.") }
        return L("Papers move to the new folder. Papers already in it join the library.")
    }

    /// "Use Default" only applies away from the default folder.
    static func isDefault(_ folder: URL) -> Bool {
        folder.standardizedFileURL == LocalStorage.defaultRoot.standardizedFileURL
    }
}
