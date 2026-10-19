#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clear data page: library + settings, and (separately) voice models
struct ClearDataPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmErase = false
    @State private var confirmModels = false
    @State private var modelBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clear data").font(.title3).fontWeight(.semibold)

            section(title: "Library and settings",
                    detail: "Deletes every paper in the library and resets all settings (server, LLM, API keys, prompts, presets). Voice models are kept.") {
                Text(LibraryPresentation.paperCount(store.papers.count))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Erase library and settings…", role: .destructive) { confirmErase = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }

            section(title: "Voice models",
                    detail: "The Kokoro voices used to speak episodes. Deleting them frees disk space; they download again the next time audio is generated.") {
                Text(ClearDataPresentation.voiceModels(bytes: modelBytes))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Delete voice models…", role: .destructive) { confirmModels = true }
                    .disabled(!ClearDataPresentation.canDeleteVoiceModels(bytes: modelBytes, conversionRunning: store.activeRun != nil))
                    .help(ClearDataPresentation.deleteVoiceModelsHelp(conversionRunning: store.activeRun != nil))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear { modelBytes = store.voiceModelsSize() }
        .confirmationDialog("Erase the library and all settings?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog("Delete the voice models?", isPresented: $confirmModels, titleVisibility: .visible) {
            Button("Delete voice models", role: .destructive) {
                store.clearVoiceModels()
                modelBytes = store.voiceModelsSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They’ll be downloaded again (about \(ClearDataPresentation.voiceModels(bytes: modelBytes))) the next time audio is generated.")
        }
    }

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
                    Text("New episode").font(.title3.weight(.semibold))
                    Text("Turn a paper into a podcast, converted on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            dropZone

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Depth", systemImage: "dial.medium")
                ForEach(Depth.allCases) { depthChoice($0) }
                if form.depth == .custom {
                    TextField("Describe the depth you want…", text: $form.depthNote, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(store.customPresets.entries) { preset in
                                Button(preset.name) { form.depthNote = preset.text }
                            }
                        } label: {
                            Label("Load preset", systemImage: "bookmark")
                        }
                        .disabled(store.customPresets.entries.isEmpty)
                        Button {
                            promptName = true
                        } label: {
                            Label("Save as preset", systemImage: "bookmark.badge.plus")
                        }
                        .disabled(!form.canSavePreset)
                        Spacer()
                    }
                    .font(.callout)
                    .controlSize(.small)
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: form.depth)

            if form.showsNoLLMWarning(llmBaseURL: store.llm.baseUrl) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No LLM is configured, so this paper will be read out as-is instead of as a discussion.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open LLM Settings…") {
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
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Start episode") {
                    if let s = form.submission {
                        store.upload(s.data, filename: s.filename, depth: s.depth, depthNote: s.depthNote)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
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
                store.show("Could not read file: \(e.localizedDescription)")
            }
        }
        .alert("Save custom depth preset", isPresented: $promptName) {
            TextField("Preset name", text: $presetName)
            Button("Save") { store.saveCustomPreset(name: presetName, text: form.depthNote) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this prompt a name so you can reload it later.")
        }
    }

    private func pick() { isImporting = true }

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
                        Text("Change…").font(.callout).foregroundStyle(Color.appAccent)
                    }
                    .padding(14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(isTargeted ? Color.appAccent : Color.secondary)
                            .symbolEffect(.bounce, value: isTargeted)
                        Text("Drop a PDF here").font(.callout.weight(.medium))
                        Text("or click to choose a file").font(.caption).foregroundStyle(.secondary)
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

    private func depthChoice(_ d: Depth) -> some View {
        let selected = form.depth == d
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            form.depth = d
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: ImportForm.icon(for: d))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.appAccent)
                    .frame(width: 32, height: 32)
                    .background(selected ? AnyShapeStyle(Color.appAccent.gradient) : AnyShapeStyle(Color.appAccent.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.label).font(.headline)
                    Text(d.blurb).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
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
    }
}

// MARK: - Edit metadata sheet
struct EditMetaSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let paper: Paper
    @State private var form: MetadataForm

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
                    Text("Edit paper").font(.title3.weight(.semibold))
                    Text(paper.filename ?? paper.displayTitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    TextField("Title", text: $form.title)
                    TextField("Filename", text: $form.filename, prompt: Text("Shown in the library list"))
                    TextField("DOI", text: $form.doi, prompt: Text("10.xxxx/xxxxx"))
                }
                Section {
                    TextField("Authors", text: $form.authors, prompt: Text("One per line"), axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Authors")
                } footer: {
                    Text("One author per line.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Affiliations") {
                    TextField("Affiliations", text: $form.affiliations, prompt: Text("One per line"), axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
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
struct ServerSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = ServerSettingsForm(ServerConfig(apiBase: "", token: ""))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection settings").font(.title3).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage server URL").font(.caption)
                TextField("http://host:9170", text: $form.apiBase).textFieldStyle(.roundedBorder)
                Text("Optional storage_server.py for sharing the library between Macs. Leave empty to keep papers on this Mac. Conversion always runs in the app.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API token").font(.caption)
                SecureField("token (optional)", text: $form.token).textFieldStyle(.roundedBorder)
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
struct LLMSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = LLMSettingsForm(LLMSettings(baseUrl: "", apiKey: "", model: "", keyEnv: ""))
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LLM Settings").font(.title3).fontWeight(.semibold)
            Text("The in-app pipeline calls this OpenAI-compatible chat endpoint to turn a PDF into a podcast script; audio is synthesized on this Mac with on-device Kokoro voices.")
                .font(.caption).foregroundStyle(.secondary)
            field("LLM base URL") { TextField("http://localhost:3000/api", text: $form.baseUrl).textFieldStyle(.roundedBorder) }

            field("API key source") {
                Picker("", selection: $form.keySource) {
                    ForEach(LLMKeySource.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            KeySourceFields(form: $form)

            field("Model") { modelPicker }
            if let err = modelError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Refresh models") { loadModels() }
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
            TextField("llama3.1:70b (manual)", text: $form.model).textFieldStyle(.roundedBorder)
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

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            content()
        }
    }
}

// MARK: - Voices page: where speech is synthesized
struct VoicesSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = SpeechSettingsForm(SpeechSettings())
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Voices").font(.title3).fontWeight(.semibold)
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
    @Binding var form: Form

    var body: some View {
        switch form.keySource {
        case .env:
            if form.envOptions.isEmpty {
                Text("No API-key env vars are set. Add one (e.g. OPENWEBUI_API_KEY) and reopen this window.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Environment var", selection: $form.selectedEnv) {
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

// MARK: - Editable LLM prose prompts (data-format / fix-query prompts excluded)
struct PromptsSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var prompts = PromptSettings.defaults

    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Query prompts").font(.title3).fontWeight(.semibold)
            Text("Customise the LLM's context and instructions. Reply-format prompts and the outline repair query are locked to keep replies parseable. Tokens: {host}, {expert}, {minutes}, {minSeg}, {maxSeg}, {plannedWords}, {depthGuide}.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("", selection: $selected) {
                Text("Outline rules").tag(0)
                Text("Personas").tag(1)
                Text("Monologue").tag(2)
                Text("Ear style").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selected {
                case 0: detail("Outline planning rules",
                               usedWhen: "When the LLM plans the episode: it breaks the paper into a section index and designs the listening segments before any dialogue is written.",
                               text: $prompts.outlineRules)
                case 1: detail("Host & expert personas",
                               usedWhen: "When the LLM writes the two-speaker conversational dialogue segments — {host} asks the questions, {expert} (the author) carries the technical content.",
                               text: $prompts.dialoguePersona)
                case 2: detail("Monologue persona",
                               usedWhen: "When the LLM writes a technical section as a single long spoken monologue delivered by the first author, {expert}.",
                               text: $prompts.monologuePersona)
                default: detail("Write-for-the-ear style",
                                usedWhen: "Applied on top of the other prompts to all generated text, so it reads naturally when spoken by the TTS engine.",
                                text: $prompts.writeForEar)
                }
            }
            .animation(.snappy, value: selected)

            Spacer(minLength: 0)
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

    private func detail(_ title: String, usedWhen: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(usedWhen).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func save() { store.savePrompts(prompts) }
}

// MARK: - Editable custom-depth prompt presets (the "Custom" option in import)
struct CustomPresetsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var entries: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        var name: String
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt presets").font(.title3).fontWeight(.semibold)
            Text("Custom depth prompts selectable from the upload sheet's Custom mode. Each preset is a named set of extra instructions sent to the LLM.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { entries.append(Entry(name: "New prompt", text: "")) } label: {
                    Label("Add preset", systemImage: "plus")
                }
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($entries) { $e in
                        card($e)
                    }
                    if entries.isEmpty {
                        ContentUnavailableView("No presets yet", systemImage: "slider.horizontal.3",
                                               description: Text("Add one with the + button above."))
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

    private func card(_ e: Binding<Entry>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Prompt name", text: e.name)
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

    private func save() {
        store.savePresets(PresetsForm.clean(entries.map { ($0.name, $0.text) }))
    }
}

// MARK: - Unified settings window with a sidebar of pages
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
                    Label("LLM Settings", systemImage: "waveform").tag(0)
                    Label("Voices", systemImage: "person.wave.2").tag(AppStore.SettingsPage.voices.rawValue)
                    Label("Server Settings", systemImage: "server.rack").tag(1)
                    Label("Query Prompts", systemImage: "quote.bubble").tag(2)
                    Label("Prompt Presets", systemImage: "slider.horizontal.3").tag(3)
                    Label("Clear Data", systemImage: "trash").tag(4)
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
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SettingsActionBar {
                if store.settingsPage == .prompts {
                    Button("Restore prompt defaults") { restorePrompts() }
                }
                Spacer()
                if showSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveCurrent() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 720, height: 560)
        .tint(Color.appAccent)
    }

    private func restorePrompts() {
        NotificationCenter.default.post(name: .papertalkRestorePrompts, object: nil)
    }

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
struct CastSheet: View {
    let paperTitle: String
    @EnvironmentObject private var store: AppStore
    @State private var form: CastForm

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
                Button("Cancel import") { store.cancelCast() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Use these voices") { store.resolveCast(form.cast) }
                    .buttonStyle(.glassProminent)
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
                Text("Who should speak?").font(.title3.weight(.semibold))
                Text(paperTitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(paperTitle)
            }
        }
    }

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

    private func nameBinding(_ row: CastForm.Row) -> Binding<String> {
        Binding(get: { row.name }, set: { form.rename(row.id, to: $0) })
    }

    @ViewBuilder private func nameField(_ row: CastForm.Row) -> some View {
        if form.picksFromAuthors(row) {
            Picker("Author", selection: nameBinding(row)) {
                if let placeholder = form.authorPlaceholder(row) {
                    Text(placeholder).tag(row.name)
                }
                ForEach(form.authors, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("The interviewed scientist is one of the paper's authors")
        } else {
            TextField("Name", text: nameBinding(row))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func voicePicker(_ row: CastForm.Row) -> some View {
        Picker("Voice", selection: Binding(
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

    private func genderPicker(_ row: CastForm.Row) -> some View {
        Picker("Gender", selection: Binding(
            get: { row.gender ?? "" },
            set: { if !$0.isEmpty { form.setGender(row.id, $0) } }
        )) {
            Text("Female").tag("female")
            Text("Male").tag("male")
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
                Text("Speaking pace").font(.callout.weight(.medium))
                Spacer()
                if !SpeakingPacePresentation.isDefault(player.voiceSpeed) {
                    Button("Reset") {
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
                    .help("Slower")
                Slider(value: $player.voiceSpeed, in: PlayerController.speedRange, step: 0.05) {
                    Text("Speaking pace")
                } onEditingChanged: { editing in
                    if !editing { playSample() }
                }
                .labelsHidden()
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    .help("Faster")
            }
            Text("Used for this episode's voices and remembered for the next import. Release the slider to hear it.")
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

    private var label: String { VoiceSamplePresentation.label(phase, modelLoaded: player.modelLoaded) }
    private var help: String { VoiceSamplePresentation.help(phase, voice: voice) }

    private func tap() {
        if VoiceSamplePresentation.tapStops(phase) { player.stopPreview() } else { player.previewVoice(voice) }
    }
}

extension Notification.Name {
    static let papertalkSaveSettings = Notification.Name("papertalkSaveSettings")
    static let papertalkRestorePrompts = Notification.Name("papertalkRestorePrompts")
}
#endif
