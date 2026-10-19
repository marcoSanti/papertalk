#if os(macOS)
import SwiftUI

/// Where voices are synthesized: the same fields in Settings and in the setup
/// wizard. Asks the server for its models and voices to fill the pickers.
struct SpeechSettingsFields: View {
    @Binding var form: SpeechSettingsForm
    @State private var loading = false
    @State private var note: FormNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $form.engine) {
                ForEach(SpeechSettings.Engine.allCases, id: \.self) { e in
                    Text(SpeechSettingsForm.engineTitle(e)).tag(e)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(SpeechSettingsForm.engineDescription(form.engine))
                .font(.caption).foregroundStyle(.secondary)
            if form.isRemote { remoteFields }
        }
        .onAppear { if form.canFetchCatalog { loadCatalog() } }
        .onChange(of: form.engine) { _, _ in if form.canFetchCatalog { loadCatalog() } }
    }

    @ViewBuilder private var remoteFields: some View {
        field("Server URL") {
            TextField(SpeechSettingsForm.urlPlaceholder, text: $form.baseUrl).textFieldStyle(.roundedBorder)
            Text(SpeechSettingsForm.urlHelp).font(.caption2).foregroundStyle(.secondary)
        }
        field("API key") {
            SecureField("optional", text: $form.apiKey).textFieldStyle(.roundedBorder)
        }
        field("Model") {
            if form.showsModelPicker {
                Picker("", selection: $form.model) {
                    ForEach(form.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(SpeechSettingsForm.modelPlaceholder, text: $form.model).textFieldStyle(.roundedBorder)
            }
        }
        Text(SpeechSettingsForm.voicesHelp).font(.caption).foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(SpeechRole.allCases) { role in
                GridRow {
                    Text(SpeechSettingsForm.roleLabel(role)).font(.caption)
                    voiceField(role)
                }
            }
        }
        HStack(spacing: 8) {
            Button(loading ? "Asking the server…" : "Refresh models and voices") { loadCatalog() }
                .disabled(loading || !form.canFetchCatalog)
            if loading { ProgressView().controlSize(.small) }
        }
        if let note {
            Text(note.text).font(.caption).foregroundStyle(note.isError ? Color.red : Color.secondary)
        }
    }

    @ViewBuilder private func voiceField(_ role: SpeechRole) -> some View {
        if form.showsVoicePickers {
            Picker("", selection: $form.voices[role]) {
                ForEach(form.voiceOptions(for: role), id: \.id) { Text($0.label).tag($0.id) }
            }
            .labelsHidden()
        } else {
            TextField(SpeechSettingsForm.ownVoiceLabel, text: $form.voices[role]).textFieldStyle(.roundedBorder)
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            content()
        }
    }

    private func loadCatalog() {
        loading = true
        note = nil
        Task {
            let catalog = await form.fetchCatalog()
            note = form.apply(catalog)
            loading = false
        }
    }
}

#endif
