import Foundation

/// What a speech server says it offers, or why it couldn't be asked.
struct SpeechCatalog: Equatable {
    var models: [String] = []
    var voices: [String] = []
    var error: String?
}

/// A line under the speech settings: a problem, or what the server offered.
struct FormNote: Equatable {
    let text: String
    let isError: Bool
}

/// Where voices are synthesized, as edited in Settings and in the setup wizard.
struct SpeechSettingsForm: Equatable, KeySourceEditing {
    var engine: SpeechSettings.Engine
    var baseUrl: String
    var keySource: LLMKeySource
    var selectedEnv: String
    var manualKey = ""
    let setEnvVars: [String]
    var model: String
    var parallelRequests: Int
    /// What the server listed on the last fetch (empty until then, or if it lists none).
    private(set) var models: [String] = []
    private(set) var serverVoices: [String] = []

    init(_ s: SpeechSettings, setEnvVars: [String] = candidateKeyEnvs()) {
        self.setEnvVars = setEnvVars
        engine = s.engine
        baseUrl = s.baseUrl
        selectedEnv = s.keyEnv
        keySource = LLMKeySource(keyEnv: s.keyEnv, apiKey: s.apiKey)
        if keySource == .manual { manualKey = s.apiKey }
        model = s.model
        parallelRequests = s.parallelRequests
    }

    var isRemote: Bool { engine == .remote }

    private var trimmedBaseURL: String {
        baseUrl.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    var canFetchCatalog: Bool { isRemote && !trimmedBaseURL.isEmpty }

    /// The settings to save. Remote fields are kept when switching to this
    /// machine, so switching back doesn't mean typing them again.
    var settings: SpeechSettings {
        SpeechSettings(engine: engine, baseUrl: trimmedBaseURL, apiKey: keyFields.apiKey, keyEnv: keyFields.keyEnv,
                       model: model.trimmingCharacters(in: .whitespaces), parallelRequests: parallelRequests)
    }

    /// Ask the server for its models and voices.
    func fetchCatalog() async -> SpeechCatalog {
        let client = RemoteSpeechClient(settings: settings, apiKey: effectiveKey(), attempts: 1)
        do {
            let models = try await client.listModels()
            let voices = try await client.listVoices()
            return SpeechCatalog(models: models, voices: voices)
        } catch {
            return SpeechCatalog(error: error.localizedDescription)
        }
    }

    /// Take in a fetched catalog: keep the chosen model if the server offers
    /// it, else pick one it offers. Returns the note to show.
    mutating func apply(_ catalog: SpeechCatalog) -> FormNote? {
        if let error = catalog.error { return FormNote(text: error, isError: true) }
        models = catalog.models
        serverVoices = catalog.voices
        if !models.isEmpty, !models.contains(model) {
            model = models.first { $0.lowercased().contains("kokoro") } ?? models[0]
        }
        // Each paper's cast picks Kokoro voices, sent to the server as they are.
        if !serverVoices.isEmpty, !serverVoices.contains(where: { KokoroSpeech.allVoices.contains($0) }) {
            return FormNote(text: Self.notKokoroVoices, isError: true)
        }
        return Self.note(models: models.count, voices: serverVoices.count)
    }

    static let notKokoroVoices = "This server doesn't list Kokoro's voices (like af_heart). "
        + "The cast's voices are sent by name, so set the server's speech engine to Kokoro."

    static func note(models: Int, voices: Int) -> FormNote {
        let found = [models > 0 ? LibraryPresentation.count(models, "model", "models") : nil,
                     voices > 0 ? LibraryPresentation.count(voices, "voice", "voices") : nil].compactMap { $0 }
        guard !found.isEmpty else {
            return FormNote(text: "The server didn't list models or voices. Type the model name.", isError: false)
        }
        let more = models == 0 ? " Type the model name." : ""
        return FormNote(text: "Found \(found.joined(separator: " and ")).\(more)", isError: false)
    }

    var showsModelPicker: Bool { !models.isEmpty }

    /// Stepper text, e.g. "4 at a time".
    var parallelLabel: String { "\(parallelRequests) at a time" }

    static func engineTitle(_ engine: SpeechSettings.Engine) -> String {
        switch engine {
        case .local: return "On \(Device.this)"
        case .remote: return "Speech server"
        }
    }

    static func engineDescription(_ engine: SpeechSettings.Engine) -> String {
        switch engine {
        case .local: return "Kokoro voices, synthesized on \(Device.this). Downloads the model once and uses about half a gigabyte of memory while voicing."
        case .remote: return "An OpenAI-compatible text-to-speech server running Kokoro, such as Open WebUI or Kokoro-FastAPI. Nothing is loaded on \(Device.this)."
        }
    }

    static let urlPlaceholder = "http://localhost:3000/api/v1"
    static let urlHelp = "Papertalk calls /audio/speech under this URL. For Open WebUI, use its address followed by /api/v1."
    static let modelPlaceholder = "\(SpeechSettings.fallbackModel) (manual)"
    static let parallelHelp = "How many sections are sent to the server at once while voicing a paper. More is faster if the server can keep up."

    /// Review lines in the setup wizard.
    var summary: [(label: String, value: String)] {
        let s = settings
        guard s.engine == .remote else { return [("Voices", Self.engineTitle(.local))] }
        return [("Voices", s.baseUrl.isEmpty ? "Speech server (no URL)" : s.baseUrl),
                ("Voice model", s.model.isEmpty ? SpeechSettings.fallbackModel : s.model)]
    }
}
