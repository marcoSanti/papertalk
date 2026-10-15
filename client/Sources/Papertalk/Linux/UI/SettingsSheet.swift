#if os(Linux)
import Foundation
import SwiftCrossUI

/// LLM and storage settings on one page; on first launch it's the setup.
/// Saves silently, with an inline "Saved", like the macOS Settings pages.
struct SettingsSheet: View {
    var bridge: StoreBridge
    let isSetup: Bool
    @State var llm: LLMSettingsForm
    @State var server: ServerSettingsForm
    @State var models: [String] = []
    @State var status = ""

    init(bridge: StoreBridge, isSetup: Bool) {
        self.bridge = bridge
        self.isSetup = isSetup
        _llm = State(wrappedValue: LLMSettingsForm(bridge.store.llm))
        _server = State(wrappedValue: ServerSettingsForm(bridge.store.config))
    }

    var body: some View {
        let keySources = LLMKeySource.allCases.map { PickerOption(value: $0, description: $0.rawValue) }
        let modelOptions = models.map { PickerOption(value: $0, description: $0) }
        let envOptions = llm.envOptions.map { PickerOption(value: $0, description: $0) }
        VStack(alignment: .leading, spacing: 10) {
            Text(SettingsSheetPresentation.title(isSetup: isSetup)).font(.title2)
            Text(SettingsSheetPresentation.intro).foregroundColor(.gray)

            Text("LLM").font(.headline)
            TextField("LLM base URL, e.g. http://localhost:3000/api", text: $llm.baseUrl)
            HStack(spacing: 8) {
                TextField("Model, e.g. llama3.1:70b", text: $llm.model)
                Button("Refresh models") { refreshModels() }
                    .disabled(!llm.canFetchModels)
            }
            if !modelOptions.isEmpty {
                Picker(of: modelOptions, selection: Binding(
                    get: { modelOptions.first { $0.value == llm.model } },
                    set: { if let m = $0 { llm.model = m.value } }))
            }
            HStack(spacing: 8) {
                Text("API key")
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

            Text("Storage server").font(.headline)
            TextField("Storage server URL (optional)", text: $server.apiBase)
            SecureField("API token", text: $server.token)
            Text(SettingsSheetPresentation.serverHelp).font(.caption).foregroundColor(.gray)

            HStack(spacing: 8) {
                Text(status).foregroundColor(.gray)
                Spacer()
                Button("Close") { bridge.store.closeSettings() }
                Button(SettingsSheetPresentation.saveTitle(isSetup: isSetup)) { save() }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

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

    private func save() {
        let store = bridge.store
        if isSetup {
            store.finishSetup(server: server.configFromURL, llm: llm.settings)
        } else {
            store.saveLLMSettings(llm.settings)
            store.saveServerSettings(server.configFromURL)
            status = "Saved"
        }
    }
}
#endif
