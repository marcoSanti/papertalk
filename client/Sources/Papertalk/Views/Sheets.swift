import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clear all data, settings, and cache (settings page)
struct ClearDataPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear all data").font(.title3).fontWeight(.semibold)
            Text("This permanently deletes every paper in the library, resets all settings (server, LLM, prompts, first-run flag), and removes the Kokoro model cache. This cannot be undone.")
                .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Papers: \(store.papers.count)")
                .font(.callout)
            Button("Erase everything", role: .destructive) { confirm = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .confirmationDialog("Delete all papers, settings and cache?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) {
                store.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Upload sheet: pick a PDF, choose episode depth, start.
struct UploadSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var pdfData: Data?
    @State private var depth: Depth = .inDepth
    @State private var depthNote = ""
    @State private var isImporting = false

    private var hasFile: Bool { pdfData != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How in-depth should this episode be?")
                .font(.title3).fontWeight(.semibold)
            if let f = fileURL {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").foregroundStyle(Color.accentColor)
                    Text(f.lastPathComponent).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Choose another…") { pick() }.buttonStyle(.link)
                }
            } else {
                Button {
                    pick()
                } label: {
                    Label("Choose a PDF…", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()
            VStack(spacing: 10) {
                depthChoice(.inDepth)
                depthChoice(.summary)
                depthChoice(.custom)
                if depth == .custom {
                    TextField("Describe the depth you want…", text: $depthNote, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start episode") {
                    if let d = pdfData, let name = fileURL?.lastPathComponent {
                        store.upload(d, filename: name, depth: depth, depthNote: depthNote)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasFile)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                _ = url.startAccessingSecurityScopedResource()
                pdfData = try? Data(contentsOf: url)
                fileURL = url
            case .failure(let e):
                store.show("Could not read file: \(e.localizedDescription)")
            }
        }
    }

    private func pick() { isImporting = true }

    private func depthChoice(_ d: Depth) -> some View {
        Button {
            depth = d
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: depth == d ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(depth == d ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.label).font(.headline)
                    Text(d.blurb).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(depth == d ? Color.accentColor.opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(depth == d ? Color.accentColor : .clear, lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit paper").font(.title3).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption)
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Authors").font(.caption)
                TextField("One per line", text: $authors, axis: .vertical).lineLimit(3, reservesSpace: true).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Affiliations").font(.caption)
                TextField("One per line", text: $affils, axis: .vertical).lineLimit(3, reservesSpace: true).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DOI").font(.caption)
                TextField("10.xxxx/xxxxx", text: $doi).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Filename").font(.caption)
                TextField("Shown in the library list", text: $filename).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let a = authors.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let af = affils.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.saveEditableMeta(paper.id, title: title, filename: filename, authors: a, affiliations: af, doi: doi)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            title = paper.title ?? ""
            authors = paper.authors.joined(separator: "\n")
            affils = paper.affiliations.joined(separator: "\n")
            doi = paper.doi ?? ""
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
                Text("Library server API base URL").font(.caption)
                TextField("http://localhost:8170/api", text: $apiBase).textFieldStyle(.roundedBorder)
                Text("Server that stores papers & runs conversions.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API token").font(.caption)
                SecureField("token (optional)", text: $token).textFieldStyle(.roundedBorder)
            }
            HStack {
                if saved { Text("Saved ✓").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Save & reconnect") { save() }.buttonStyle(.borderedProminent)
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
        store.config = ServerConfig(apiBase: trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression), token: token)
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
            Text("The in-app pipeline calls this OpenAI-compatible chat endpoint to turn a PDF into a podcast script; audio is synthesized with system voices on this Mac.")
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
            HStack {
                if saved { Text("Saved ✓").font(.caption).foregroundStyle(.secondary) }
                if let err = modelError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Refresh models") { loadModels() }
                    .disabled(loadingModels || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
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
    }

    @ViewBuilder private var modelPicker: some View {
        if loadingModels {
            ProgressView().controlSize(.small)
        } else if models.isEmpty {
            TextField("llama3.1:70b (manual)", text: $model).textFieldStyle(.roundedBorder)
                .disabled(true)
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
        store.llm = LLMSettings(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces),
                                apiKey: apiKey,
                                model: model.trimmingCharacters(in: .whitespaces),
                                keyEnv: keyEnv)
        store.llm.saveResolvedKey()
        store.show("LLM settings saved")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Query prompts").font(.title3).fontWeight(.semibold)
            Text("Customise the LLM's context and instructions. Reply-format prompts and the outline repair query are locked to keep replies parseable. Tokens: {host}, {expert}, {minutes}, {minSeg}, {maxSeg}, {plannedWords}, {depthGuide}.")
                .font(.caption).foregroundStyle(.secondary)
            editor("Outline planning rules", $outlineRules, tall: true)
            editor("Host & expert personas", $dialoguePersona, tall: false)
            editor("Monologue persona", $monologuePersona, tall: false)
            editor("Write-for-the-ear style", $writeForEar, tall: true)
            HStack {
                if saved { Text("Saved ✓").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Restore defaults") { load(PromptSettings.defaults); saved = false }
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .onAppear { load(store.prompts) }
        .onDisappear { save() }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in save() }
    }

    private func editor(_ label: String, _ t: Binding<String>, tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            TextEditor(text: t)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: tall ? 76 : 46)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
        }
    }

    private func load(_ p: PromptSettings) {
        outlineRules = p.outlineRules
        dialoguePersona = p.dialoguePersona
        monologuePersona = p.monologuePersona
        writeForEar = p.writeForEar
    }

    private func save() {
        store.prompts = PromptSettings(outlineRules: outlineRules, dialoguePersona: dialoguePersona,
                                       monologuePersona: monologuePersona, writeForEar: writeForEar)
        store.show("Prompts saved")
        saved = true
    }
}

// MARK: - Unified settings window with a sidebar of pages
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("papertalk.settingsPage") private var pageRaw: Int = 0

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
        NavigationSplitView {
            List(selection: selectedIndex) {
                Label("LLM Settings", systemImage: "waveform").tag(0)
                Label("Server Settings", systemImage: "server.rack").tag(1)
                Label("Query Prompts", systemImage: "quote.bubble").tag(2)
                Label("Clear Data", systemImage: "trash").tag(3)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 190)
        } detail: {
            Group {
                switch store.settingsPage {
                case .llm: LLMSettingsPage()
                case .server: ServerSettingsPage()
                case .prompts: PromptsSettingsPage()
                case .clear: ClearDataPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveCurrent() }
            }
        }
        .frame(width: 720, height: 560)
    }

    private func saveCurrent() {
        NotificationCenter.default.post(name: .papertalkSaveSettings, object: nil)
    }
}

extension Notification.Name {
    static let papertalkSaveSettings = Notification.Name("papertalkSaveSettings")
}