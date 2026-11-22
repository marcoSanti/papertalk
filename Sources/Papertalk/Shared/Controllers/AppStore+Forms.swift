// What the forms need from outside the app: the servers' lists and the chosen PDF's bytes.

import Foundation

extension AppStore {
    /// Ask the endpoint in `form` for its models.
    func fetchModels(_ form: LLMSettingsForm) async throws -> [String] {
        try await LocalPipeline(baseUrl: form.trimmedBaseURL, apiKey: form.effectiveKey(), model: form.model).listModels()
    }

    /// Ask the speech server in `form` for its models and voices.
    nonisolated static func fetchCatalog(_ form: SpeechSettingsForm) async -> SpeechCatalog {
        let client = RemoteSpeechClient(settings: form.settings, apiKey: form.effectiveKey(), attempts: 1)
        do {
            let models = try await client.listModels()
            let voices = try await client.listVoices()
            return SpeechCatalog(models: models, voices: voices)
        } catch {
            return SpeechCatalog(error: error.localizedDescription)
        }
    }

    /// The chosen PDF's bytes; nil, with a toast saying why, when it can't be read.
    func readPDF(_ url: URL) -> Data? {
        do { return try PDFFile.read(url) } catch { show(error.localizedDescription); return nil }
    }
}
