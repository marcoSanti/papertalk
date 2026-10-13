import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clear all data, settings, and cache
struct ClearDataSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear all data").font(.title3).fontWeight(.semibold)
            Text("This permanently deletes every paper in the library, resets all settings (server, LLM, first-run flag), and removes the Kokoro model cache. This cannot be undone.")
                .font(.caption).foregroundStyle(.secondary)
            .frame(width: 400, alignment: .leading)
            Text("Papers: \(store.papers.count)")
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Erase everything", role: .destructive) { confirm = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .confirmationDialog("Delete all papers, settings and cache?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) {
                store.clearAll()
                dismiss()
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

// MARK: - Connection sheet (which server this app points at)
struct ConnectionSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var apiBase = ""
    @State private var token = ""

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
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & reconnect") {
                    let trimmed = apiBase.trimmingCharacters(in: .whitespaces)
                    // empty = self-hosted (store locally, run pipeline in this app)
                    store.config = ServerConfig(apiBase: trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression), token: token)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            apiBase = store.config.apiBase
            token = store.config.token
        }
    }
}

// MARK: - LLM settings sheet
struct LLMSettingsSheet: View {
    enum KeySource: String, CaseIterable, Identifiable {
        case none = "No key"
        case env = "From environment"
        case manual = "Type a key"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseUrl = ""
    @State private var model = ""
    @State private var keySource: KeySource = .none
    @State private var selectedEnv = ""
    @State private var manualKey = ""
    @State private var saving = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    private let envOptions = candidateKeyEnvs()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LLM Settings").font(.title3).fontWeight(.semibold)
            Text("The in-app pipeline calls this OpenAI-compatible chat endpoint to turn a PDF into a podcast script; audio is synthesized with system voices on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            field("LLM base URL") { TextField("http://localhost:3000/api", text: $baseUrl).textFieldStyle(.roundedBorder) }

            field("API key source") {
                Picker("", selection: $keySource) {
                    ForEach(KeySource.allCases) { s in Text(s.rawValue).tag(s) }
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
                if let err = modelError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(loadingModels ? "Loading…" : "Refresh models") { loadModels() }
                    .disabled(loadingModels || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            baseUrl = store.llm.baseUrl
            model = store.llm.model
            let env = store.llm.keyEnv
            if envOptions.contains(env) {
                keySource = .env
                selectedEnv = env
            } else if !store.llm.apiKey.isEmpty {
                keySource = .manual
                manualKey = store.llm.apiKey
            } else {
                keySource = .none
            }
            if !baseUrl.isEmpty { loadModels() }
        }
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
        store.show("LLM settings saved")
        saving = false
        dismiss()
    }
}