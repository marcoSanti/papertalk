// The Voices settings fields, shared by Settings and setup.

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
        .onChange(of: form.keySource) { _, _ in form.keySourceChanged() }
    }

    @ViewBuilder private var remoteFields: some View {
        CaptionedField(label: L("Server URL")) {
            TextField(SpeechSettingsForm.urlPlaceholder, text: $form.baseUrl).textFieldStyle(.roundedBorder)
            Text(SpeechSettingsForm.urlHelp).font(.caption2).foregroundStyle(.secondary)
        }
        KeySourceSection(form: $form)
        CaptionedField(label: L("Model")) {
            if form.showsModelPicker {
                Picker("", selection: $form.model) {
                    ForEach(form.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(SpeechSettingsForm.modelPlaceholder, text: $form.model).textFieldStyle(.roundedBorder)
            }
        }
        CaptionedField(label: L("Requests at a time")) {
            Stepper(form.parallelLabel, value: $form.parallelRequests, in: SpeechSettings.parallelRange)
            Text(SpeechSettingsForm.parallelHelp).font(.caption2).foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            Button(SpeechSettingsForm.refreshTitle(loading: loading)) { loadCatalog() }
                .disabled(loading || !form.canFetchCatalog)
            if loading { ProgressView().controlSize(.small) }
        }
        if let note {
            Text(note.text).font(.caption).foregroundStyle(note.isError ? Color.red : Color.secondary)
        }
    }

    /// Ask the server for its models and voices, and show what came back.
    private func loadCatalog() {
        loading = true
        note = nil
        Task {
            let catalog = await AppStore.fetchCatalog(form)
            note = form.apply(catalog)
            loading = false
        }
    }
}

#endif
