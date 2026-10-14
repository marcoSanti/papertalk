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
                Text(store.papers.count == 1 ? "1 paper" : "\(store.papers.count) papers")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Erase library and settings…", role: .destructive) { confirmErase = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }

            section(title: "Voice models",
                    detail: "The Kokoro voices used to speak episodes. Deleting them frees disk space; they download again the next time audio is generated.") {
                Text(modelBytes > 0 ? ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file) : "Not downloaded")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Delete voice models…", role: .destructive) { confirmModels = true }
                    .disabled(modelBytes == 0 || store.activeRun != nil)
                    .help(store.activeRun != nil ? "Wait for conversions to finish" : "")
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
            Text("They’ll be downloaded again (about \(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))) the next time audio is generated.")
        }
    }

    private func section<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    @State private var fileURL: URL?
    @State private var pdfData: Data?
    @State private var depth: Depth = .inDepth
    @State private var depthNote = ""
    @State private var presetName = ""
    @State private var promptName = false
    @State private var isImporting = false
    @State private var isTargeted = false

    private var hasFile: Bool { pdfData != nil }
    private var needsLLM: Bool { depth != .direct }
    private var canStart: Bool {
        hasFile && (depth != .custom || !depthNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

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
                if depth == .custom {
                    TextField("Describe the depth you want…", text: $depthNote, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(store.customPresets.entries) { preset in
                                Button(preset.name) { depthNote = preset.text }
                            }
                        } label: {
                            Label("Load preset", systemImage: "bookmark")
                        }
                        .disabled(store.customPresets.entries.isEmpty)
                        Button {
                            guard !depthNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            promptName = true
                        } label: {
                            Label("Save as preset", systemImage: "bookmark.badge.plus")
                        }
                        Spacer()
                    }
                    .font(.callout)
                    .controlSize(.small)
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: depth)

            if needsLLM && store.llm.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
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
                    if let d = pdfData, let name = fileURL?.lastPathComponent {
                        store.upload(d, filename: name, depth: depth, depthNote: depthNote)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canStart)
                .help(canStart ? "" : (hasFile ? "Describe the depth you want first" : "Choose a PDF first"))
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
            Button("Save") { store.saveCustomPreset(name: presetName, text: depthNote) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this prompt a name so you can reload it later.")
        }
    }

    private func pick() { isImporting = true }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            store.show("Could not read \(url.lastPathComponent)")
            return
        }
        withAnimation(.snappy) {
            pdfData = data
            fileURL = url
        }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: pick) {
            Group {
                if let f = fileURL {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if let n = pdfData?.count {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file))
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
                shape.strokeBorder(isTargeted || hasFile ? Color.appAccent.opacity(0.7) : Color.secondary.opacity(0.4),
                                   style: StrokeStyle(lineWidth: 1.5, dash: hasFile ? [] : [6, 4]))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            load(url)
            return true
        } isTargeted: { t in
            withAnimation(.snappy(duration: 0.15)) { isTargeted = t }
        }
    }

    private func icon(_ d: Depth) -> String {
        switch d {
        case .inDepth: return "books.vertical"
        case .summary: return "text.append"
        case .custom: return "slider.horizontal.3"
        case .direct: return "text.quote"
        }
    }

    private func depthChoice(_ d: Depth) -> some View {
        let selected = depth == d
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            depth = d
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon(d))
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
    @State private var title = ""
    @State private var authors = ""
    @State private var affils = ""
    @State private var doi = ""
    @State private var filename = ""

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
                    TextField("Title", text: $title)
                    TextField("Filename", text: $filename, prompt: Text("Shown in the library list"))
                    TextField("DOI", text: $doi, prompt: Text("10.xxxx/xxxxx"))
                }
                Section {
                    TextField("Authors", text: $authors, prompt: Text("One per line"), axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Authors")
                } footer: {
                    Text("One author per line.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Affiliations") {
                    TextField("Affiliations", text: $affils, prompt: Text("One per line"), axis: .vertical)
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
                    let a = authors.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let af = affils.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.saveEditableMeta(paper.id, title: title, filename: filename, authors: a, affiliations: af, doi: doi)
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
        .onAppear {
            title = paper.title ?? ""
            authors = paper.authors.joined(separator: "\n")
            affils = paper.affiliations.joined(separator: "\n")
            doi = paper.doi
            filename = paper.filename ?? ""
        }
    }
}

// MARK: - Server settings page (which server this app points at)
struct ServerSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var apiBase = ""
    @State private var token = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection settings").font(.title3).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage server URL").font(.caption)
                TextField("http://host:9170", text: $apiBase).textFieldStyle(.roundedBorder)
                Text("Optional storage_server.py for sharing the library between Macs. Leave empty to keep papers on this Mac. Conversion always runs in the app.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API token").font(.caption)
                SecureField("token (optional)", text: $token).textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .onAppear {
            apiBase = store.config.apiBase
            token = store.config.token
        }
        .onDisappear { save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in save() }
    }

    private func save() {
        let trimmed = apiBase.trimmingCharacters(in: .whitespaces)
        // empty = self-hosted (store locally, run pipeline in this app)
        let next = ServerConfig(apiBase: trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression), token: token)
        if next != store.config { store.config = next }
        saved = true
    }
}

// MARK: - LLM API key source selection (shared by LLM settings + onboarding)
enum LLMKeySource: String, CaseIterable, Identifiable {
    case none = "No key"
    case env = "From environment"
    case manual = "Type a key"
    var id: String { rawValue }
}

// MARK: - LLM settings page
struct LLMSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var baseUrl = ""
    @State private var model = ""
    @State private var keySource: LLMKeySource = .none
    @State private var selectedEnv = ""
    @State private var manualKey = ""
    @State private var saving = false
    @State private var saved = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    private var envOptions: [String] {
        var opts = candidateKeyEnvs()
        if !selectedEnv.isEmpty && !opts.contains(selectedEnv) { opts.insert(selectedEnv, at: 0) }
        return opts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LLM Settings").font(.title3).fontWeight(.semibold)
            Text("The in-app pipeline calls this OpenAI-compatible chat endpoint to turn a PDF into a podcast script; audio is synthesized on this Mac with on-device Kokoro voices.")
                .font(.caption).foregroundStyle(.secondary)
            field("LLM base URL") { TextField("http://localhost:3000/api", text: $baseUrl).textFieldStyle(.roundedBorder) }

            field("API key source") {
                Picker("", selection: $keySource) {
                    ForEach(LLMKeySource.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if keySource == .env {
                if envOptions.isEmpty {
                    Text("No API-key env vars are set. Add one (e.g. OPENWEBUI_API_KEY) and reopen this window.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Environment var", selection: $selectedEnv) {
                        ForEach(envOptions, id: \.self) { v in Text(v).tag(v) }
                    }
                    .pickerStyle(.menu)
                }
            } else if keySource == .manual {
                SecureField("sk-…", text: $manualKey).textFieldStyle(.roundedBorder)
            }

            field("Model") { modelPicker }
            if let err = modelError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Refresh models") { loadModels() }
                    .disabled(loadingModels || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .onAppear {
            baseUrl = store.llm.baseUrl
            model = store.llm.model
            let env = store.llm.keyEnv
            selectedEnv = env
            if !env.isEmpty {
                keySource = .env
            } else if !store.llm.apiKey.isEmpty {
                keySource = .manual
                manualKey = store.llm.apiKey
            } else {
                keySource = .none
            }
            if !baseUrl.isEmpty { loadModels() }
        }
        .onDisappear { save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in save() }
        .onChange(of: keySource) { _, source in
            if source == .env, selectedEnv.isEmpty { selectedEnv = envOptions.first ?? "" }
        }
    }

    @ViewBuilder private var modelPicker: some View {
        if loadingModels {
            ProgressView().controlSize(.small)
        } else if models.isEmpty {
            TextField("llama3.1:70b (manual)", text: $model).textFieldStyle(.roundedBorder)
        } else {
            Picker("", selection: $model) {
                ForEach(models, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var effectiveKey: String {
        switch keySource {
        case .env: return ProcessInfo.processInfo.environment[selectedEnv] ?? ""
        case .manual: return manualKey
        case .none: return ""
        }
    }

    private func loadModels() {
        loadingModels = true
        modelError = nil
        Task {
            do {
                let p = LocalPipeline(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces),
                                      apiKey: effectiveKey.trimmingCharacters(in: .whitespaces), model: model)
                let ids = try await p.listModels()
                models = ids
                if !ids.contains(model) { model = ids.first ?? model }
                if models.isEmpty { modelError = "No models returned by /models" }
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

    private func save() {
        saving = true
        var keyEnv = ""
        var apiKey = ""
        switch keySource {
        case .env: keyEnv = selectedEnv
        case .manual: apiKey = manualKey.trimmingCharacters(in: .whitespaces)
        case .none: break
        }
        let next = LLMSettings(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces),
                               apiKey: apiKey,
                               model: model.trimmingCharacters(in: .whitespaces),
                               keyEnv: keyEnv)
        if next != store.llm {
            store.llm = next
            store.llm.saveResolvedKey()
        }
        saved = true
        saving = false
    }
}

// MARK: - Editable LLM prose prompts (data-format / fix-query prompts excluded)
struct PromptsSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var outlineRules = ""
    @State private var dialoguePersona = ""
    @State private var monologuePersona = ""
    @State private var writeForEar = ""
    @State private var saved = false

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
                               text: $outlineRules)
                case 1: detail("Host & expert personas",
                               usedWhen: "When the LLM writes the two-speaker conversational dialogue segments — {host} asks the questions, {expert} (the author) carries the technical content.",
                               text: $dialoguePersona)
                case 2: detail("Monologue persona",
                               usedWhen: "When the LLM writes a technical section as a single long spoken monologue delivered by the first author, {expert}.",
                               text: $monologuePersona)
                default: detail("Write-for-the-ear style",
                                usedWhen: "Applied on top of the other prompts to all generated text, so it reads naturally when spoken by the TTS engine.",
                                text: $writeForEar)
                }
            }
            .animation(.snappy, value: selected)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(20)
        .onAppear { load(store.prompts) }
        .onDisappear { save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkRestorePrompts)) { _ in
            load(PromptSettings.defaults); saved = false
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

    private func load(_ p: PromptSettings) {
        outlineRules = p.outlineRules
        dialoguePersona = p.dialoguePersona
        monologuePersona = p.monologuePersona
        writeForEar = p.writeForEar
    }

    private func save() {
        let next = PromptSettings(outlineRules: outlineRules, dialoguePersona: dialoguePersona,
                                  monologuePersona: monologuePersona, writeForEar: writeForEar)
        if next != store.prompts { store.prompts = next }
        saved = true
    }
}

// MARK: - Editable custom-depth prompt presets (the "Custom" option in import)
struct CustomPresetsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var entries: [Entry] = []
    @State private var saved = false

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
                Button { entries.append(Entry(name: "New prompt", text: "")); saved = false } label: {
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
                Button(role: .destructive) { entries.removeAll { $0.id == e.wrappedValue.id }; saved = false } label: {
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
        var seen = Set<String>()
        var clean: [CustomDepthPresets.Entry] = []
        for e in entries {
            let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !text.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            clean.append(.init(name: name, text: text))
        }
        store.customPresets = CustomDepthPresets(entries: clean)
        store.customPresets.save()
        saved = true
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
    let proposals: [ProposedSpeaker]
    let authors: [String]
    /// Author full name -> gender, from the LLM.
    let authorGenders: [String: String]
    @EnvironmentObject private var store: AppStore

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var role: String
        var name: String
        var voice: String
        /// "male" / "female", or nil when neither the LLM nor the name tells.
        var gender: String?
    }
    @State private var rows: [Row]

    init(paperTitle: String, proposals: [ProposedSpeaker], authors: [String], authorGenders: [String: String]) {
        self.paperTitle = paperTitle
        self.proposals = proposals
        self.authors = authors
        self.authorGenders = authorGenders
        _rows = State(initialValue: Self.initialRows(proposals))
    }

    /// Default voices: the interviewer keeps the show's signature voice, each
    /// guest gets a different voice of their own gender.
    private static func initialRows(_ proposals: [ProposedSpeaker]) -> [Row] {
        var rows = proposals.map { Row(role: $0.role, name: $0.name, voice: $0.voice, gender: $0.gender) }
        var used = Set<String>()
        // The interviewer is the show's constant: they keep the signature voice
        // of their gender (Heart / Michael) in every episode.
        for i in rows.indices where isHost(rows[i].role) {
            rows[i].voice = KokoroSpeech.defaultVoice(forGender: proposals[i].gender, avoiding: used)
            used.insert(rows[i].voice)
        }
        // Each guest gets a voice of their gender the host doesn't use, varied
        // per author instead of always the same one.
        for i in rows.indices where !isHost(rows[i].role) {
            rows[i].voice = KokoroSpeech.guestVoice(forGender: proposals[i].gender, name: rows[i].name, avoiding: used)
            used.insert(rows[i].voice)
        }
        return rows
    }

    /// The host/anchor speaks for the show; everything else is an interviewed
    /// author, whose name is picked from the paper's real authors.
    private static func isHost(_ role: String) -> Bool {
        let r = role.lowercased()
        return r.contains("interviewer") || r.contains("host") || r.contains("anchor")
            || r.contains("moderator") || r.contains("presenter")
    }

    private var trimmedNames: [String] { rows.map { $0.name.trimmingCharacters(in: .whitespaces) } }
    private var hasEmptyName: Bool { trimmedNames.contains { $0.isEmpty } }
    private var hasDuplicateName: Bool {
        Set(trimmedNames.map { $0.lowercased() }).count < trimmedNames.count
    }
    private var sharesVoice: Bool { Set(rows.map(\.voice)).count < rows.count }
    private var canConfirm: Bool { !rows.isEmpty && !hasEmptyName && !hasDuplicateName }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 10) {
                ForEach($rows) { $row in speakerCard($row) }
            }
            .animation(.snappy, value: rows)

            speedControl

            validation

            HStack {
                Spacer()
                Button("Cancel import") { store.cancelCast() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Use these voices") {
                    let cast = zip(rows, trimmedNames).map { SpeakerConfig(name: $1, voice: $0.voice) }
                    store.resolveCast(cast)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canConfirm)
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

    private func speakerCard(_ row: Binding<Row>) -> some View {
        let r = row.wrappedValue
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(alignment: .top, spacing: 12) {
            AuthorAvatar(name: r.name.isEmpty ? r.role : r.name, size: 40)
                .animation(.snappy, value: r.name)
            VStack(alignment: .leading, spacing: 8) {
                Text(r.role.uppercased())
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
                    VoiceSampleButton(player: store.player, voice: r.voice)
                }
            }
        }
        .padding(12)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private func nameField(_ row: Binding<Row>) -> some View {
        if !Self.isHost(row.wrappedValue.role) && !authors.isEmpty {
            Picker("Author", selection: Binding(
                get: { row.wrappedValue.name },
                set: { rename(row, to: $0) }
            )) {
                if !authors.contains(row.wrappedValue.name) {
                    Text(row.wrappedValue.name.isEmpty ? "Choose an author…" : row.wrappedValue.name)
                        .tag(row.wrappedValue.name)
                }
                ForEach(authors, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("The interviewed scientist is one of the paper's authors")
        } else {
            TextField("Name", text: Binding(
                get: { row.wrappedValue.name },
                set: { rename(row, to: $0) }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private func voicePicker(_ row: Binding<Row>) -> some View {
        Picker("Voice", selection: Binding(
            get: { row.wrappedValue.voice },
            set: { v in
                row.wrappedValue.voice = v
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
        .help("\(KokoroSpeech.accent(row.wrappedValue.voice)) · \(KokoroSpeech.voiceGender(row.wrappedValue.voice) ?? "voice")")
    }

    /// Rename a speaker. The voice is left untouched: gender comes from the LLM's
    /// cast, not a name heuristic, so changing a name doesn't silently change voice.
    /// Rename a speaker. Picking a different author also takes that author's
    /// gender (from the LLM, else their first name), which re-voices them.
    private func rename(_ row: Binding<Row>, to name: String) {
        row.wrappedValue.name = name
        guard !Self.isHost(row.wrappedValue.role), authors.contains(name) else { return }
        if let g = authorGenders[name] ?? KokoroSpeech.guessGender(fromName: name) {
            setGender(row, g)
        }
    }

    /// Change a speaker's gender; if their voice doesn't match it any more, give
    /// them the default voice for it (host: signature voice; guest: per-author).
    private func setGender(_ row: Binding<Row>, _ gender: String) {
        row.wrappedValue.gender = gender
        let r = row.wrappedValue
        guard KokoroSpeech.voiceGender(r.voice) != gender else { return }
        let others = Set(rows.filter { $0.id != r.id }.map(\.voice))
        row.wrappedValue.voice = Self.isHost(r.role)
            ? KokoroSpeech.defaultVoice(forGender: gender, avoiding: others)
            : KokoroSpeech.guestVoice(forGender: gender, name: r.name, avoiding: others)
    }

    private func genderPicker(_ row: Binding<Row>) -> some View {
        Picker("Gender", selection: Binding(
            get: { row.wrappedValue.gender ?? "" },
            set: { if !$0.isEmpty { setGender(row, $0) } }
        )) {
            Text("Female").tag("female")
            Text("Male").tag("male")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(row.wrappedValue.gender == nil
              ? "Gender unknown — pick one so the voice fits"
              : "Switching gender picks a matching voice")
    }

    private var speedControl: some View {
        SpeakingPaceControl(player: store.player,
                            sampleVoice: { store.player.preview?.voice ?? rows.last?.voice })
    }

    @ViewBuilder private var validation: some View {
        if hasEmptyName || hasDuplicateName {
            Label(hasEmptyName ? "Every speaker needs a name." : "Each speaker needs a different name.",
                  systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let unknown = rows.first(where: { $0.gender == nil }) {
            Label("Couldn't tell \(unknown.name.isEmpty ? unknown.role : unknown.name)'s gender — choose Female or Male so the voice fits.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if sharesVoice {
            Label("Speakers share a voice, so they'll be hard to tell apart.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("Each person's voice is used whenever they speak. Choosing a voice plays a short sample.")
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

    private var isDefault: Bool { abs(player.voiceSpeed - PlayerController.defaultSpeed) < 0.001 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speaking pace").font(.callout.weight(.medium))
                Spacer()
                if !isDefault {
                    Button("Reset") {
                        player.voiceSpeed = PlayerController.defaultSpeed
                        playSample()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Text(String(format: "%.2f×", player.voiceSpeed))
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
            if player.voiceSpeed > 1.5 {
                Label {
                    Text("Kokoro is trained on natural-pace speech, so words may slur above 1.5× — listen to a sample first. "
                         + "Episodes also get shorter: a 30-minute summary plays in about \(Int((30 * PlayerController.defaultSpeed / player.voiceSpeed).rounded())) minutes at this pace.")
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
        .animation(.snappy, value: player.voiceSpeed > 1.5)
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
        player.preview?.voice == voice ? player.preview : nil
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

    private var label: String {
        switch phase {
        case .generating: return player.modelLoaded ? "Generating…" : "Loading voices…"
        case .playing: return "Playing"
        case .failed: return "Retry"
        case nil: return "Sample"
        }
    }

    private var help: String {
        switch phase {
        case .generating: return "Synthesizing a sample of \(KokoroSpeech.displayName(voice)) — click to cancel"
        case .playing: return "Stop the sample"
        case .failed(_, let msg): return "Couldn't play the sample: \(msg)"
        case nil: return "Hear \(KokoroSpeech.displayName(voice))"
        }
    }

    private func tap() {
        switch phase {
        case .generating, .playing: player.stopPreview()
        default: player.previewVoice(voice)
        }
    }
}

extension Notification.Name {
    static let papertalkSaveSettings = Notification.Name("papertalkSaveSettings")
    static let papertalkRestorePrompts = Notification.Name("papertalkRestorePrompts")
}