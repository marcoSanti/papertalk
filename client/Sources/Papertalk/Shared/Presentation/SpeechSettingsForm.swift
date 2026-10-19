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
struct SpeechSettingsForm: Equatable {
    var engine: SpeechSettings.Engine
    var baseUrl: String
    var apiKey: String
    var model: String
    var voices: SpeechVoiceRoles
    /// What the server listed on the last fetch (empty until then, or if it lists none).
    private(set) var models: [String] = []
    private(set) var serverVoices: [String] = []

    init(_ s: SpeechSettings) {
        engine = s.engine
        baseUrl = s.baseUrl
        apiKey = s.apiKey
        model = s.model
        voices = s.voices
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
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        return SpeechSettings(engine: engine, baseUrl: trimmedBaseURL, apiKey: trim(apiKey), model: trim(model),
                              voices: SpeechVoiceRoles(hostFemale: trim(voices.hostFemale), hostMale: trim(voices.hostMale),
                                                       guestFemale: trim(voices.guestFemale), guestMale: trim(voices.guestMale)))
    }

    /// Ask the server for its models and voices.
    func fetchCatalog() async -> SpeechCatalog {
        let client = RemoteSpeechClient(settings: settings, attempts: 1)
        do {
            let models = try await client.listModels()
            let voices = try await client.listVoices()
            return SpeechCatalog(models: models, voices: voices)
        } catch {
            return SpeechCatalog(error: error.localizedDescription)
        }
    }

    /// Whether the server speaks with Kokoro's own voice ids.
    var serverHasKokoroVoices: Bool { serverVoices.contains { KokoroSpeech.allVoices.contains($0) } }

    /// Take in a fetched catalog: keep the chosen model and voices where the
    /// server offers them, else pick from what it offers. Returns the note to show.
    mutating func apply(_ catalog: SpeechCatalog) -> FormNote? {
        if let error = catalog.error { return FormNote(text: error, isError: true) }
        models = catalog.models
        serverVoices = catalog.voices
        if !models.isEmpty, !models.contains(model) {
            model = models.first { $0.lowercased().contains("kokoro") } ?? models[0]
        }
        if !serverVoices.isEmpty {
            let kokoro = serverHasKokoroVoices
            for (i, role) in SpeechRole.allCases.enumerated() {
                let current = voices[role]
                if current.isEmpty ? !kokoro : !serverVoices.contains(current) {
                    // A Kokoro server can take the cast's voices as they are;
                    // any other gets a distinct server voice per role.
                    voices[role] = kokoro ? "" : serverVoices[i % serverVoices.count]
                }
            }
        }
        return Self.note(models: models.count, voices: serverVoices.count)
    }

    static func note(models: Int, voices: Int) -> FormNote {
        switch (models, voices) {
        case (0, 0):
            return FormNote(text: "The server didn't list models or voices. Type the model name; "
                + "each paper's Kokoro voices are sent as they are.", isError: false)
        case (_, 0):
            return FormNote(text: "Found \(LibraryPresentation.count(models, "model", "models")). The server didn't list voices, "
                + "so each paper's Kokoro voices are sent as they are.", isError: false)
        case (0, _):
            return FormNote(text: "Found \(LibraryPresentation.count(voices, "voice", "voices")). Type the model name.", isError: false)
        default:
            return FormNote(text: "Found \(LibraryPresentation.count(models, "model", "models")) and \(LibraryPresentation.count(voices, "voice", "voices")).", isError: false)
        }
    }

    /// Choices for a role's picker: the cast's own Kokoro voice (when the
    /// server has Kokoro voices), then every server voice.
    func voiceOptions(for role: SpeechRole) -> [(id: String, label: String)] {
        let own = serverHasKokoroVoices ? [("", Self.ownVoiceLabel)] : []
        var options = own + serverVoices.map { ($0, $0) }
        let current = voices[role]
        if !current.isEmpty, !serverVoices.contains(current) { options.insert((current, current), at: 0) }
        return options
    }

    /// Pickers once the server has listed voices; text fields otherwise.
    var showsVoicePickers: Bool { !serverVoices.isEmpty }
    var showsModelPicker: Bool { !models.isEmpty }

    static let ownVoiceLabel = "The cast's Kokoro voice"

    static func roleLabel(_ role: SpeechRole) -> String {
        switch role {
        case .hostFemale: return "Female host (Heart)"
        case .hostMale: return "Male host (Michael)"
        case .guestFemale: return "Female guests"
        case .guestMale: return "Male guests"
        }
    }

    static func engineTitle(_ engine: SpeechSettings.Engine) -> String {
        switch engine {
        case .local: return "On \(Device.this)"
        case .remote: return "Speech server"
        }
    }

    static func engineDescription(_ engine: SpeechSettings.Engine) -> String {
        switch engine {
        case .local: return "Kokoro voices, synthesized on \(Device.this). Downloads the model once and uses about half a gigabyte of memory while voicing."
        case .remote: return "An OpenAI-compatible text-to-speech server, such as Open WebUI or Kokoro-FastAPI. Nothing is loaded on \(Device.this)."
        }
    }

    static let urlPlaceholder = "http://localhost:3000/api/v1"
    static let urlHelp = "Papertalk calls /audio/speech under this URL. For Open WebUI, use its address followed by /api/v1."
    static let voicesHelp = "Papers keep their Kokoro voices. Pick the server voice used for each part of the cast, "
        + "or leave a field empty to send the Kokoro voice name as it is."
    static let modelPlaceholder = "\(SpeechSettings.fallbackModel) (manual)"

    /// Review lines in the setup wizard.
    var summary: [(label: String, value: String)] {
        let s = settings
        guard s.engine == .remote else { return [("Voices", Self.engineTitle(.local))] }
        return [("Voices", s.baseUrl.isEmpty ? "Speech server (no URL)" : s.baseUrl),
                ("Voice model", s.model.isEmpty ? SpeechSettings.fallbackModel : s.model)]
    }
}
