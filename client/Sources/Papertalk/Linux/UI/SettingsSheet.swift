// The Linux settings sheet, also the first-run setup: language, LLM and storage server.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// LLM and storage settings on one page; on first launch it's the setup.
/// Saves silently, with an inline "Saved", like the macOS Settings pages.
struct SettingsSheet: View {
    var bridge: StoreBridge
    /// First-run setup: Finish saves everything and closes.
    let isSetup: Bool
    @State var llm: LLMSettingsForm
    @State var server: ServerSettingsForm
    @State var models: [String] = []
    /// The line by the buttons: "Saved" or why models couldn't be listed.
    @State var status = ""

    /// The forms start from the saved settings.
    init(bridge: StoreBridge, isSetup: Bool) {
        self.bridge = bridge
        self.isSetup = isSetup
        _llm = State(wrappedValue: LLMSettingsForm(bridge.store.llm))
        _server = State(wrappedValue: ServerSettingsForm(bridge.store.config))
    }

    var body: some View {
        let keySources = LLMKeySource.allCases.map { PickerOption(value: $0, description: $0.label) }
        let modelOptions = models.map { PickerOption(value: $0, description: $0) }
        let envOptions = llm.envOptions.map { PickerOption(value: $0, description: $0) }
        let languages = LanguagePresentation.options.map { PickerOption(value: $0.language, description: $0.title) }
        VStack(alignment: .leading, spacing: 10) {
            Text(SettingsSheetPresentation.title(isSetup: isSetup)).font(.title2)
            Text(SettingsSheetPresentation.intro).foregroundColor(.gray)

            HStack(spacing: 8) {
                Text(LanguagePresentation.pickerLabel)
                Picker(of: languages, selection: Binding(
                    get: { languages.first { $0.value == bridge.store.language } },
                    set: { if let l = $0 { bridge.store.setLanguage(l.value) } }))
            }
            Text(LanguagePresentation.intro).font(.caption).foregroundColor(.gray)

            Text(L("LLM")).font(.headline)
            TextField(L("LLM base URL, e.g. http://localhost:3000/api"), text: $llm.baseUrl)
            HStack(spacing: 8) {
                TextField(L("Model, e.g. llama3.1:70b"), text: $llm.model)
                Button(L("Refresh models")) { refreshModels() }
                    .disabled(!llm.canFetchModels)
            }
            if !modelOptions.isEmpty {
                Picker(of: modelOptions, selection: Binding(
                    get: { modelOptions.first { $0.value == llm.model } },
                    set: { if let m = $0 { llm.model = m.value } }))
            }
            HStack(spacing: 8) {
                Text(L("API key"))
                Picker(of: keySources, selection: Binding(
                    get: { keySources.first { $0.value == llm.keySource } },
                    set: { if let k = $0 { llm.keySource = k.value; llm.keySourceChanged() } }))
            }
            if llm.keySource == .env {
                if envOptions.isEmpty {
                    Text(SettingsSheetPresentation.noEnvVars).foregroundColor(.orange)
                } else {
                    Picker(of: envOptions, selection: Binding(
                        get: { envOptions.first { $0.value == llm.selectedEnv } },
                        set: { if let e = $0 { llm.selectedEnv = e.value } }))
                }
            }
            if llm.keySource == .manual {
                SecureField("sk-…", text: $llm.manualKey)
            }

            Text(L("Storage server")).font(.headline)
            TextField(L("Storage server URL (optional)"), text: $server.apiBase)
            SecureField(L("API token"), text: $server.token)
            Text(SettingsSheetPresentation.serverHelp).font(.caption).foregroundColor(.gray)

            HStack(spacing: 8) {
                Text(status).foregroundColor(.gray)
                Spacer()
                Button(L("Close")) { bridge.store.closeSettings() }
                Button(SettingsSheetPresentation.saveTitle(isSetup: isSetup)) { save() }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    /// List the endpoint's models into the picker.
    private func refreshModels() {
        Task {
            do {
                let ids = try await llm.fetchModels()
                models = ids
                status = llm.applyModels(ids) ?? ""
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// Finish setup, or save the changed settings and say so.
    private func save() {
        status = bridge.store.saveSettingsSheet(isSetup: isSetup, llm: llm.settings, server: server.configFromURL) ?? status
    }
}
#endif
