// The Voices settings form (Settings and setup): where speech is synthesized, the speech
// server's URL, key, model and parallelism, and what the server says it offers.

import Foundation

/// What a speech server says it offers, or why it couldn't be asked.
struct SpeechCatalog: Equatable {
    /// Model ids from the server.
    var models: [String] = []
    /// Voice ids from the server.
    var voices: [String] = []
    /// Why listing failed, if it did.
    var error: String?
}

/// A line under the speech settings: a problem, or what the server offered.
struct FormNote: Equatable {
    /// The line to show.
    let text: String
    /// Drawn as a problem (red) rather than information.
    let isError: Bool
}

/// Where voices are synthesized, as edited in Settings and in the setup wizard.
struct SpeechSettingsForm: Equatable, KeySourceEditing {
    /// On this machine, or a speech server.
    var engine: SpeechSettings.Engine
    /// The server URL as typed.
    var baseUrl: String
    /// Where the server's key comes from.
    var keySource: LLMKeySource
    /// Used when `keySource` is `.env`.
    var selectedEnv: String
    /// Used when `keySource` is `.manual`.
    var manualKey = ""
    /// Key variables that are set right now.
    let setEnvVars: [String]
    /// The server's model id; empty sends `SpeechSettings.fallbackModel`.
    var model: String
    /// Requests in flight at once while voicing.
    var parallelRequests: Int
    /// What the server listed on the last fetch (empty until then, or if it lists none).
    private(set) var models: [String] = []
    private(set) var serverVoices: [String] = []

    /// The form showing the saved settings `s`.
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

    /// The server fields are shown only for a speech server.
    var isRemote: Bool { engine == .remote }

    private var trimmedBaseURL: String {
        baseUrl.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    /// Asking needs a server URL.
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

    /// The server offers voices, but none of Kokoro's (which every cast uses).
    static var notKokoroVoices: String {
        L("This server doesn't list Kokoro's voices (like af_heart). The cast's voices are sent by name, so set the server's speech engine to Kokoro.")
    }

    /// What a fetch found, e.g. "Found 2 models and 54 voices."
    static func note(models: Int, voices: Int) -> FormNote {
        let found = [models > 0 ? LibraryPresentation.count(models, L("1 model"), L("{0} models")) : nil,
                     voices > 0 ? LibraryPresentation.count(voices, L("1 voice"), L("{0} voices")) : nil].compactMap { $0 }
        guard !found.isEmpty else {
            return FormNote(text: L("The server didn't list models or voices. Type the model name."), isError: false)
        }
        let more = models == 0 ? " " + L("Type the model name.") : ""
        return FormNote(text: L("Found {0}.", found.joined(separator: L(" and "))) + more, isError: false)
    }

    /// A menu once the server listed models; a text field until then.
    var showsModelPicker: Bool { !models.isEmpty }

    /// Stepper text, e.g. "4 at a time".
    var parallelLabel: String { L("{0} at a time", parallelRequests) }

    /// Each engine's choice title.
    static func engineTitle(_ engine: SpeechSettings.Engine) -> String {
        switch engine {
        case .local: return Device.on
        case .remote: return L("Speech server")
        }
    }

    /// Under each engine choice.
    static func engineDescription(_ engine: SpeechSettings.Engine) -> String {
        switch engine {
        case .local: return L("Kokoro voices, synthesized on {0}. Downloads the model once and uses about half a gigabyte of memory while voicing.", Device.this)
        case .remote: return L("An OpenAI-compatible text-to-speech server running Kokoro, such as Open WebUI or Kokoro-FastAPI. Nothing is loaded on {0}.", Device.this)
        }
    }

    /// The URL field's placeholder.
    static let urlPlaceholder = "http://localhost:3000/api/v1"
    /// Under the URL field.
    static var urlHelp: String { L("Papertalk calls /audio/speech under this URL. For Open WebUI, use its address followed by /api/v1.") }
    /// The model field's placeholder.
    static var modelPlaceholder: String { L("{0} (manual)", SpeechSettings.fallbackModel) }
    /// Under the parallel-requests stepper.
    static var parallelHelp: String { L("How many sections are sent to the server at once while voicing a paper. More is faster if the server can keep up.") }

    /// Review lines in the setup wizard.
    var summary: [(label: String, value: String)] {
        let s = settings
        guard s.engine == .remote else { return [(L("Voices"), Self.engineTitle(.local))] }
        return [(L("Voices"), s.baseUrl.isEmpty ? L("Speech server (no URL)") : s.baseUrl),
                (L("Voice model"), s.model.isEmpty ? SpeechSettings.fallbackModel : s.model)]
    }
}
