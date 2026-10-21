// The macOS sheets: import (New episode), Edit paper, the cast (Who should speak?), and the
// Settings window with its pages (LLM, Voices, Server, Query Prompts, Prompt Presets,
// Language, Clear Data). Settings pages save when they close or Save is pressed.

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clear data page: library + settings, and (separately) voice models
/// Erase the library and settings, the listened-audio question, and the voice models.
struct ClearDataPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmErase = false
    @State private var confirmModels = false
    @State private var modelBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Clear data")).font(.title3).fontWeight(.semibold)

            section(title: L("Library and settings"),
                    detail: L("Deletes every paper in the library and resets all settings (server, LLM, API keys, prompts, presets). Voice models are kept.")) {
                Text(LibraryPresentation.paperCount(store.papers.count))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Erase library and settings…"), role: .destructive) { confirmErase = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }

            section(title: L("Audio of finished episodes"),
                    detail: L("When an episode has been listened to the end, ask whether to delete its audio. The script is always kept.")) {
                Toggle(L("Ask after listening"), isOn: $store.askToDeleteListenedAudio)
                Spacer()
            }

            section(title: L("Voice models"),
                    detail: L("The Kokoro voices used to speak episodes. Deleting them frees disk space; they download again the next time audio is generated.")) {
                Text(ClearDataPresentation.voiceModels(bytes: modelBytes))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Delete voice models…"), role: .destructive) { confirmModels = true }
                    .disabled(!ClearDataPresentation.canDeleteVoiceModels(bytes: modelBytes, conversionRunning: store.activeRun != nil))
                    .help(ClearDataPresentation.deleteVoiceModelsHelp(conversionRunning: store.activeRun != nil))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear { modelBytes = store.voiceModelsSize() }
        .confirmationDialog(L("Erase the library and all settings?"), isPresented: $confirmErase, titleVisibility: .visible) {
            Button(L("Erase everything"), role: .destructive) { store.clearAll() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This can’t be undone."))
        }
        .confirmationDialog(L("Delete the voice models?"), isPresented: $confirmModels, titleVisibility: .visible) {
            Button(L("Delete voice models"), role: .destructive) {
                store.clearVoiceModels()
                modelBytes = store.voiceModelsSize()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("They’ll be downloaded again (about {0}) the next time audio is generated.", ClearDataPresentation.voiceModels(bytes: modelBytes)))
        }
    }

    /// A titled, explained group with its controls on one line.
    private func section<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            // No .fixedSize here: inside the split view it stretched the sidebar's
            // table thousands of points tall, scrolled to the bottom and blank.
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack { content() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Upload sheet: pick (or drop) a PDF, choose episode depth, start.
/// The import sheet: choose or drop a PDF, pick the depth (and a summary's length), optionally
/// the episode language, then start.
struct UploadSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var form = ImportForm()
    @State private var presetName = ""
    @State private var promptName = false
    @State private var isImporting = false
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.appAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ImportForm.heading).font(.title3.weight(.semibold))
                    Text(ImportForm.subheading)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            dropZone

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: L("Depth"), systemImage: "dial.medium")
                // A 2×2 grid with one shared blurb keeps the sheet short enough for small screens.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Depth.allCases) { depthChoice($0) }
                }
                Text(form.depth.blurb)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                if form.depth == .custom {
                    TextField(L("Describe the depth you want…"), text: $form.depthNote, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(store.customPresets.entries) { preset in
                                Button(preset.name) { form.depthNote = preset.text }
                            }
                        } label: {
                            Label(L("Load preset"), systemImage: "bookmark")
                        }
                        .disabled(store.customPresets.entries.isEmpty)
                        Button {
                            promptName = true
                        } label: {
                            Label(L("Save as preset"), systemImage: "bookmark.badge.plus")
                        }
                        .disabled(!form.canSavePreset)
                        Spacer()
                    }
                    .font(.callout)
                    .controlSize(.small)
                    .transition(.opacity)
                }
                if form.showsLengthSlider {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("Length")).font(.callout.weight(.medium))
                            Spacer()
                            Text(form.lengthLabel).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $form.summaryMinutes, in: ImportForm.lengthRange, step: ImportForm.lengthStep) {
                            Text(L("Length"))
                        } minimumValueLabel: {
                            Text(ImportForm.lengthMinLabel).font(.caption)
                        } maximumValueLabel: {
                            Text(ImportForm.lengthMaxLabel).font(.caption)
                        }
                        .labelsHidden()
                    }
                    .help(ImportForm.lengthHelp)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.snappy, value: form.depth)

            if form.showsLanguageToggle {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(ImportForm.languageToggleTitle, isOn: $form.writeInAppLanguage)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.callout.weight(.medium))
                    Text(ImportForm.languageToggleHelp)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }

            if form.showsNoLLMWarning(llmBaseURL: store.llm.baseUrl) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ImportForm.noLLMWarning)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Open LLM Settings…")) {
                            dismiss()
                            store.settingsPage = .llm
                            store.showSettings = true
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .buttonStyle(.tinted(.gray))
                    .keyboardShortcut(.cancelAction)
                Button(L("Start episode")) {
                    if let s = form.submission {
                        store.upload(s.data, filename: s.filename, depth: s.depth, depthNote: s.depthNote,
                                     targetMinutes: s.targetMinutes, scriptLanguage: s.scriptLanguage)
                        dismiss()
                    }
                }
                .buttonStyle(.tinted(Color.appAccent, prominent: true))
                .disabled(!form.canStart)
                .help(form.startHelp)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .tint(Color.appAccent)
        .onAppear {
            if let url = store.pendingUploadURL {
                store.pendingUploadURL = nil
                load(url)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                load(url)
            case .failure(let e):
                store.show(L("Could not read file: {0}", e.localizedDescription))
            }
        }
        .alert(L("Save custom depth preset"), isPresented: $promptName) {
            TextField(L("Preset name"), text: $presetName)
            Button(L("Save")) { store.saveCustomPreset(name: presetName, text: form.depthNote) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Give this prompt a name so you can reload it later."))
        }
    }

    /// Open the file picker.
    private func pick() { isImporting = true }

    /// Read the chosen PDF into the form (a toast if it can't be read).
    private func load(_ url: URL) {
        do {
            let data = try PDFFile.read(url)
            withAnimation(.snappy) { form.setFile(name: url.lastPathComponent, data: data) }
        } catch {
            store.show(error.localizedDescription)
        }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: pick) {
            Group {
                if let name = form.fileName {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if let size = form.fileSizeLabel {
                                Text(size)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(L("Change…")).font(.callout).foregroundStyle(Color.appAccent)
                    }
                    .padding(14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(isTargeted ? Color.appAccent : Color.secondary)
                            .symbolEffect(.bounce, value: isTargeted)
                        Text(L("Drop a PDF here")).font(.callout.weight(.medium))
                        Text(L("or click to choose a file")).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }
            }
            .frame(maxWidth: .infinity)
            .background(shape.fill(Color.appAccent.opacity(isTargeted ? 0.12 : 0.04)))
            .overlay(
                shape.strokeBorder(isTargeted || form.hasFile ? Color.appAccent.opacity(0.7) : Color.secondary.opacity(0.4),
                                   style: StrokeStyle(lineWidth: 1.5, dash: form.hasFile ? [] : [6, 4]))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = ImportPresentation.firstPDF(in: urls) else { return false }
            load(url)
            return true
        } isTargeted: { t in
            withAnimation(.snappy(duration: 0.15)) { isTargeted = t }
        }
    }

    /// A selectable depth card.
    private func depthChoice(_ d: Depth) -> some View {
        let selected = form.depth == d
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            form.depth = d
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: ImportForm.icon(for: d))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.appAccent)
                    .frame(width: 32, height: 32)
                    .background(selected ? AnyShapeStyle(Color.appAccent.gradient) : AnyShapeStyle(Color.appAccent.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(d.label).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.appAccent : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(10)
            .background(shape.fill(Color.appAccent.opacity(selected ? 0.10 : 0.0)))
            .overlay(shape.strokeBorder(selected ? Color.appAccent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(d.blurb)
    }
}

// MARK: - Edit metadata sheet
/// Edit a paper's title, file name, DOI, authors and affiliations.
struct EditMetaSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let paper: Paper
    @State private var form: MetadataForm

    /// The form starts from the paper's current values.
    init(paper: Paper) {
        self.paper = paper
        _form = State(initialValue: MetadataForm(paper))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PaperArtwork(paper: paper)
                    .frame(width: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Edit paper")).font(.title3.weight(.semibold))
                    Text(paper.filename ?? paper.displayTitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    TextField(L("Title"), text: $form.title)
                    TextField(L("Filename"), text: $form.filename, prompt: Text(L("Shown in the library list")))
                    TextField(L("DOI"), text: $form.doi, prompt: Text("10.xxxx/xxxxx"))
                }
                Section {
                    TextField(L("Authors"), text: $form.authors, prompt: Text(L("One per line")), axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text(L("Authors"))
                } footer: {
                    Text(L("One author per line.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Affiliations")) {
                    TextField(L("Affiliations"), text: $form.affiliations, prompt: Text(L("One per line")), axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    store.saveMetadata(paper.id, form)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 560)
        .tint(Color.appAccent)
    }
}

// MARK: - Server settings page (which server this app points at)
/// The storage server's URL and token (empty URL: this Mac).
struct ServerSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = ServerSettingsForm(ServerConfig(apiBase: "", token: ""))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Connection settings")).font(.title3).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Storage server URL")).font(.caption)
                TextField("http://host:9170", text: $form.apiBase).textFieldStyle(.roundedBorder)
                Text(L("Optional storage_server.py for sharing the library between Macs. Leave empty to keep papers on this Mac. Conversion always runs in the app.")).font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("API token")).font(.caption)
                SecureField(L("token (optional)"), text: $form.token).textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .onAppear { form = ServerSettingsForm(store.config) }
        .onDisappear { store.saveServerSettings(form.configFromURL) }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in
            store.saveServerSettings(form.configFromURL)
        }
    }
}

// MARK: - LLM settings page
/// The LLM endpoint, its key and the model (listed from `/models` when it answers).
struct LLMSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = LLMSettingsForm(LLMSettings(baseUrl: "", apiKey: "", model: "", keyEnv: ""))
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("LLM Settings")).font(.title3).fontWeight(.semibold)
            Text(L("The in-app pipeline calls this OpenAI-compatible chat endpoint to turn a PDF into a podcast script; audio is synthesized on this Mac with on-device Kokoro voices."))
                .font(.caption).foregroundStyle(.secondary)
            field(L("LLM base URL")) { TextField("http://localhost:3000/api", text: $form.baseUrl).textFieldStyle(.roundedBorder) }

            field(L("API key source")) {
                Picker("", selection: $form.keySource) {
                    ForEach(LLMKeySource.allCases) { s in Text(s.label).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            KeySourceFields(form: $form)

            field(L("Model")) { modelPicker }
            if let err = modelError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(L("Refresh models")) { loadModels() }
                    .disabled(loadingModels || !form.canFetchModels)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .onAppear {
            form = LLMSettingsForm(store.llm)
            if form.canFetchModels { loadModels() }
        }
        .onDisappear { store.saveLLMSettings(form.settings) }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in
            store.saveLLMSettings(form.settings)
        }
        .onChange(of: form.keySource) { _, _ in form.keySourceChanged() }
    }

    @ViewBuilder private var modelPicker: some View {
        if loadingModels {
            ProgressView().controlSize(.small)
        } else if models.isEmpty {
            TextField(L("llama3.1:70b (manual)"), text: $form.model).textFieldStyle(.roundedBorder)
        } else {
            Picker("", selection: $form.model) {
                ForEach(models, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// List the endpoint's models into the picker.
    private func loadModels() {
        loadingModels = true
        modelError = nil
        Task {
            do {
                let ids = try await form.fetchModels()
                models = ids
                modelError = form.applyModels(ids)
            } catch {
                modelError = error.localizedDescription
            }
            loadingModels = false
        }
    }

    /// A caption above a control.
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            content()
        }
    }
}

// MARK: - Voices page: where speech is synthesized
/// Where voices are synthesized (`SpeechSettingsFields`).
struct VoicesSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = SpeechSettingsForm(SpeechSettings())
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Voices")).font(.title3).fontWeight(.semibold)
                if loaded { SpeechSettingsFields(form: $form) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onAppear {
            form = SpeechSettingsForm(store.speech)
            loaded = true
        }
        .onDisappear { store.saveSpeechSettings(form.settings) }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in
            store.saveSpeechSettings(form.settings)
        }
    }
}

/// The key fields under the key-source picker (shared by Settings and setup).
struct KeySourceFields<Form: KeySourceEditing>: View {
    /// The LLM or speech form whose key is edited.
    @Binding var form: Form

    var body: some View {
        switch form.keySource {
        case .env:
            if form.envOptions.isEmpty {
                Text(L("No API-key env vars are set. Add one (e.g. OPENWEBUI_API_KEY) and reopen this window."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(L("Environment var"), selection: $form.selectedEnv) {
                    ForEach(form.envOptions, id: \.self) { v in Text(v).tag(v) }
                }
                .pickerStyle(.menu)
            }
        case .manual:
            SecureField("sk-…", text: $form.manualKey).textFieldStyle(.roundedBorder)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Editable LLM prompts (reply formats are appended by the pipeline)
/// Every prompt the LLM is sent, editable one at a time, with Reset.
struct PromptsSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var prompts = PromptSettings.defaults

    @State private var selected = PromptCatalog.entries[0].id

    var body: some View {
        let entry = PromptCatalog.entry(selected)
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Query prompts")).font(.title3).fontWeight(.semibold)
            Text(PromptCatalog.intro)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Picker(L("Prompt"), selection: $selected) {
                    ForEach(PromptCatalog.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.entries) { Text($0.title).tag($0.id) }
                        }
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Button(PromptCatalog.resetTitle) { entry.reset(&prompts) }
                    .disabled(entry.isDefault(prompts))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("\(entry.group) · \(entry.title)").font(.headline)
                Text(entry.usedWhen).font(.caption).foregroundStyle(.secondary)
                Text(entry.tokensLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TextEditor(text: $prompts[dynamicMember: entry.keyPath])
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(20)
        .onAppear { prompts = store.prompts }
        .onDisappear { save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkRestorePrompts)) { _ in
            prompts = PromptSettings.defaults
        }
    }

    /// Keep the edited prompts.
    private func save() { store.savePrompts(prompts) }
}

// MARK: - Editable custom-depth prompt presets (the "Custom" option in import)
/// The custom-depth presets: add, rename, edit, delete.
struct CustomPresetsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var entries: [Entry] = []

    /// A preset being edited (ids are only for the list).
    struct Entry: Identifiable {
        let id = UUID()
        var name: String
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Prompt presets")).font(.title3).fontWeight(.semibold)
            Text(L("Custom depth prompts selectable from the upload sheet's Custom mode. Each preset is a named set of extra instructions sent to the LLM."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { entries.append(Entry(name: L("New prompt"), text: "")) } label: {
                    Label(L("Add preset"), systemImage: "plus")
                }
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($entries) { $e in
                        card($e)
                    }
                    if entries.isEmpty {
                        ContentUnavailableView(L("No presets yet"), systemImage: "slider.horizontal.3",
                                               description: Text(L("Add one with the + button above.")))
                            .padding(.top, 40)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { entries = store.customPresets.entries.map { Entry(name: $0.name, text: $0.text) } }
        .onDisappear { save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in save() }
    }

    /// One preset: its name, delete button and instructions.
    private func card(_ e: Binding<Entry>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(L("Prompt name"), text: e.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Button(role: .destructive) { entries.removeAll { $0.id == e.wrappedValue.id } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextEditor(text: e.text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Keep the presets, cleaned (`PresetsForm.clean`).
    private func save() {
        store.savePresets(PresetsForm.clean(entries.map { ($0.name, $0.text) }))
    }
}

// MARK: - General: the interface language (applies at once; episodes keep their own)
struct LanguageSettingsPage: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LanguagePresentation.generalTitle).font(.title3).fontWeight(.semibold)
            Text(LanguagePresentation.intro)
                .font(.caption).foregroundStyle(.secondary)
            LanguagePicker()
                .pickerStyle(.menu)
                .fixedSize()
            Divider().padding(.vertical, 4)
            LibraryFolderSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

/// Where the local library lives, with buttons to move it.
struct LibraryFolderSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let converting = store.activeRun != nil
        let folder = store.libraryFolder
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Library folder")).font(.headline)
            Text(folder.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Group {
                    Button(L("Choose…")) { PaperPanels.chooseLibraryFolder(for: store) }
                    Button(L("Use Default")) { store.setLibraryFolder(nil) }
                        .disabled(LibraryFolderPresentation.isDefault(folder))
                }
                .disabled(!LibraryFolderPresentation.canChange(isStandalone: store.isStandalone, converting: converting))
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Text(LibraryFolderPresentation.note(isStandalone: store.isStandalone, converting: converting))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The interface language menu (shared by Settings and setup).
struct LanguagePicker: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Picker(LanguagePresentation.pickerLabel, selection: Binding(get: { store.language }, set: { store.setLanguage($0) })) {
            ForEach(LanguagePresentation.options, id: \.language) { Text($0.title).tag($0.language) }
        }
    }
}

// MARK: - Unified settings window with a sidebar of pages
/// The Settings window: a sidebar of pages and a bar with Save and Close.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("papertalk.settingsPage") private var pageRaw: Int = 0
    @State private var showSaved = false
    @State private var savedTask: Task<Void, Never>?

    private var selectedIndex: Binding<Int> {
        Binding(
            get: { store.settingsPage.rawValue },
            set: {
                pageRaw = $0
                store.settingsPage = AppStore.SettingsPage(rawValue: $0) ?? .llm
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: selectedIndex) {
                    Label(LanguagePresentation.generalTitle, systemImage: "gearshape").tag(AppStore.SettingsPage.general.rawValue)
                    Label(L("LLM Settings"), systemImage: "waveform").tag(0)
                    Label(L("Voices"), systemImage: "person.wave.2").tag(AppStore.SettingsPage.voices.rawValue)
                    Label(L("Server Settings"), systemImage: "server.rack").tag(1)
                    Label(L("Query Prompts"), systemImage: "quote.bubble").tag(2)
                    Label(L("Prompt Presets"), systemImage: "slider.horizontal.3").tag(3)
                    Label(L("Clear Data"), systemImage: "trash").tag(4)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 190)
            } detail: {
                Group {
                    switch store.settingsPage {
                    case .llm: LLMSettingsPage()
                    case .voices: VoicesSettingsPage()
                    case .server: ServerSettingsPage()
                    case .prompts: PromptsSettingsPage()
                    case .presets: CustomPresetsPage()
                    case .clear: ClearDataPage()
                    case .general: LanguageSettingsPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SettingsActionBar {
                if store.settingsPage == .prompts {
                    Button(L("Restore prompt defaults")) { restorePrompts() }
                }
                Spacer()
                if showSaved {
                    Label(L("Saved"), systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { saveCurrent() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 720, height: 560)
        .tint(Color.appAccent)
    }

    /// Ask the prompts page to put every default back.
    private func restorePrompts() {
        NotificationCenter.default.post(name: .papertalkRestorePrompts, object: nil)
    }

    /// Ask the open page to save, and flash "Saved".
    private func saveCurrent() {
        NotificationCenter.default.post(name: .papertalkSaveSettings, object: nil)
        withAnimation(.snappy) { showSaved = true }
        savedTask?.cancel()
        savedTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { withAnimation(.snappy) { showSaved = false } }
        }
    }
}

/// Bottom action bar for the unified settings window.
private struct SettingsActionBar<Content: View>: View {
    /// The bar's buttons.
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        HStack {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Cast confirmation: show the model's proposed speakers, let the user
// rename each person and pick (and hear) their voice before the script is written.
/// Confirm the cast before the script is written: each speaker's name, gender and voice (with a
/// sample), the speaking pace, then cancel, skip audio, or use these voices.
struct CastSheet: View {
    /// Shown under the heading.
    let paperTitle: String
    @EnvironmentObject private var store: AppStore
    @State private var form: CastForm

    /// The form starts from the LLM's proposal.
    init(paperTitle: String, proposals: [ProposedSpeaker], authors: [String], authorGenders: [String: String]) {
        self.paperTitle = paperTitle
        _form = State(initialValue: CastForm(proposals: proposals, authors: authors, authorGenders: authorGenders))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 10) {
                ForEach(form.rows) { row in speakerCard(row) }
            }
            .animation(.snappy, value: form.rows)

            SpeakingPaceControl(player: store.player,
                                sampleVoice: { store.player.preview?.voice ?? form.rows.last?.voice })

            validation

            HStack {
                Spacer()
                // One accent per outcome: discard (red), script only (indigo), voice it (app orange).
                Button(L("Cancel import")) { store.cancelCast() }
                    .buttonStyle(.tinted(.red))
                    .keyboardShortcut(.cancelAction)
                Button(CastForm.scriptOnlyTitle) { store.resolveCast(form.cast, voiceAudio: false) }
                    .buttonStyle(.tinted(.indigo, prominent: true))
                    .disabled(!form.canConfirm)
                    .help(CastForm.scriptOnlyHelp)
                Button(L("Use these voices")) { store.resolveCast(form.cast) }
                    .buttonStyle(.tinted(Color.appAccent, prominent: true))
                    .disabled(!form.canConfirm)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
        .tint(Color.appAccent)
        .onDisappear { store.player.stopPreview() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.appAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Who should speak?")).font(.title3.weight(.semibold))
                Text(paperTitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(paperTitle)
            }
        }
    }

    /// One speaker: role, name (an author menu for the guest), gender, voice and sample.
    private func speakerCard(_ row: CastForm.Row) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(alignment: .top, spacing: 12) {
            AuthorAvatar(name: CastForm.avatarName(row), size: 40)
                .animation(.snappy, value: row.name)
            VStack(alignment: .leading, spacing: 8) {
                Text(row.role.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                HStack(spacing: 8) {
                    nameField(row)
                    genderPicker(row)
                }
                HStack(spacing: 8) {
                    voicePicker(row)
                    Spacer(minLength: 0)
                    VoiceSampleButton(player: store.player, voice: row.voice)
                }
            }
        }
        .padding(12)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// Renames go through the form, which re-voices a guest picked from the authors.
    private func nameBinding(_ row: CastForm.Row) -> Binding<String> {
        Binding(get: { row.name }, set: { form.rename(row.id, to: $0) })
    }

    /// The guest picks from the authors; the interviewer's name is typed.
    @ViewBuilder private func nameField(_ row: CastForm.Row) -> some View {
        if form.picksFromAuthors(row) {
            Picker(L("Author"), selection: nameBinding(row)) {
                if let placeholder = form.authorPlaceholder(row) {
                    Text(placeholder).tag(row.name)
                }
                ForEach(form.authors, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(L("The interviewed scientist is one of the paper's authors"))
        } else {
            TextField(L("Name"), text: nameBinding(row))
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Voices grouped by accent and gender; choosing one plays a sample.
    private func voicePicker(_ row: CastForm.Row) -> some View {
        Picker(L("Voice"), selection: Binding(
            get: { row.voice },
            set: { v in
                form.setVoice(row.id, v)
                store.player.previewVoice(v)   // hear the choice straight away
            }
        )) {
            ForEach(KokoroSpeech.voiceGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.voices, id: \.self) { Text(KokoroSpeech.displayName($0)).tag($0) }
                }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(CastForm.voiceHelp(row.voice))
    }

    /// Female/Male; switching picks a matching voice.
    private func genderPicker(_ row: CastForm.Row) -> some View {
        Picker(L("Gender"), selection: Binding(
            get: { row.gender ?? "" },
            set: { if !$0.isEmpty { form.setGender(row.id, $0) } }
        )) {
            Text(L("Female")).tag("female")
            Text(L("Male")).tag("male")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(CastForm.genderHelp(row))
    }

    @ViewBuilder private var validation: some View {
        let note = form.note
        switch note.severity {
        case .error:
            Label(note.text, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .warning:
            Label(note.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .info:
            Text(note.text)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Speaking-pace slider for synthesis. Plays a sample at the new pace when
/// the slider is released (not on every tick: each sample is a synthesis).
private struct SpeakingPaceControl: View {
    @ObservedObject var player: PlayerController
    /// Voice to demo the pace with.
    let sampleVoice: () -> String?


    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Speaking pace")).font(.callout.weight(.medium))
                Spacer()
                if !SpeakingPacePresentation.isDefault(player.voiceSpeed) {
                    Button(L("Reset")) {
                        player.voiceSpeed = PlayerController.defaultSpeed
                        playSample()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Text(SpeakingPacePresentation.label(player.voiceSpeed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    .help(L("Slower"))
                Slider(value: $player.voiceSpeed, in: PlayerController.speedRange, step: 0.05) {
                    Text(L("Speaking pace"))
                } onEditingChanged: { editing in
                    if !editing { playSample() }
                }
                .labelsHidden()
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    .help(L("Faster"))
            }
            Text(L("Used for this episode's voices and remembered for the next import. Release the slider to hear it."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = SpeakingPacePresentation.warning(player.voiceSpeed) {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .animation(.snappy, value: SpeakingPacePresentation.warning(player.voiceSpeed) != nil)
    }

    /// Hear the pace with the sample voice.
    private func playSample() {
        if let v = sampleVoice() { player.previewVoice(v) }
    }
}

/// Play / generating / playing / failed control for a voice sample. While the
/// sample is synthesized it shows a spinner (click to cancel); while playing, a
/// progress ring around a stop button.
private struct VoiceSampleButton: View {
    @ObservedObject var player: PlayerController
    let voice: String
    @State private var hovering = false

    private var phase: PlayerController.PreviewPhase? {
        VoiceSamplePresentation.phase(player.preview, for: voice)
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 7) {
                icon.frame(width: 18, height: 18)
                Text(label)
                    .font(.callout)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy, value: phase)
        .help(help)
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .generating:
            if hovering {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .playing:
            ZStack {
                Circle().stroke(Color.appAccent.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: player.previewProgress)
                    .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: player.previewProgress)
                Image(systemName: "stop.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.appAccent)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case nil:
            Image(systemName: "play.circle.fill").foregroundStyle(Color.appAccent)
        }
    }

    private var label: String { VoiceSamplePresentation.label(phase, loadingModel: player.sampleLoadsModel) }
    private var help: String { VoiceSamplePresentation.help(phase, voice: voice) }

    /// Stop the sample, or play it.
    private func tap() {
        if VoiceSamplePresentation.tapStops(phase) { player.stopPreview() } else { player.previewVoice(voice) }
    }
}

extension Notification.Name {
    /// The Settings window's Save: each page saves its own form.
    static let papertalkSaveSettings = Notification.Name("papertalkSaveSettings")
    /// "Restore prompt defaults" on the prompts page.
    static let papertalkRestorePrompts = Notification.Name("papertalkRestorePrompts")
}
#endif
