import SwiftUI

// MARK: - First-run setup wizard: storage backend + LLM endpoint.
struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Step { case storage, llm, done }
    @State private var step: Step = .storage

    // storage
    @State private var storageMode = "local"
    @State private var apiBase = ""
    @State private var token = ""

    // llm
    @State private var baseUrl = ""
    @State private var model = ""
    @State private var keySource: LLMSettingsSheet.KeySource = .none
    @State private var selectedEnv = ""
    @State private var manualKey = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    private let envOptions = candidateKeyEnvs()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            Group {
                switch step {
                case .storage: storageView
                case .llm: llmView
                case .done: doneView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 500, height: 560)
        .onAppear {
            apiBase = store.config.apiBase
            token = store.config.token
            baseUrl = store.llm.baseUrl
            model = store.llm.model
            if envOptions.contains(store.llm.keyEnv) { keySource = .env; selectedEnv = store.llm.keyEnv }
            else if !store.llm.apiKey.isEmpty { keySource = .manual; manualKey = store.llm.apiKey }
            if !baseUrl.isEmpty { loadModels() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 28)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Papertalk").font(.title2).fontWeight(.semibold)
                Text("Set up where your papers live and which LLM writes the episodes.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func stepTitle(_ t: String) -> some View {
        Text(t).font(.headline)
    }

    // MARK: Step 1 — storage
    private var storageView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("1. Where should your library be stored?")
            HStack(spacing: 10) {
                storageCard("local", icon: "internaldrive", title: "On this Mac",
                            desc: "Files kept locally in Application Support.")
                storageCard("remote", icon: "network", title: "Storage server",
                            desc: "Point at your storage_server.py (HTTP).")
            }
            if storageMode == "remote" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server API base URL").font(.caption)
                    TextField("http://host:9170/api", text: $apiBase).textFieldStyle(.roundedBorder)
                    Text("API token").font(.caption)
                    SecureField("token (optional)", text: $token).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func storageCard(_ value: String, icon: String, title: String, desc: String) -> some View {
        Button {
            storageMode = value
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: storageMode == value ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 22))
                        .foregroundStyle(storageMode == value ? Color.accentColor : Color.secondary)
                    Spacer()
                }
                Text(title).font(.callout).fontWeight(.semibold)
                Text(desc).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(storageMode == value ? Color.accentColor.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(storageMode == value ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.borderless)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Step 2 — LLM
    private var llmView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("2. Which LLM writes the episodes?")
            Text("An OpenAI-compatible chat endpoint. Leave empty to use a plain read-through transcript (no AI).")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM base URL").font(.caption)
                TextField("http://localhost:3000/api", text: $baseUrl).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API key source").font(.caption)
                Picker("", selection: $keySource) {
                    ForEach(LLMSettingsSheet.KeySource.allCases) { s in Text(s.rawValue).tag(s) }
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
                    }.pickerStyle(.menu)
                }
            } else if keySource == .manual {
                SecureField("sk-…", text: $manualKey).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Model").font(.caption)
                Spacer()
                Button(loadingModels ? "Loading…" : "Refresh models") { loadModels() }
                    .disabled(loadingModels || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            modelPicker
        }
    }

    @ViewBuilder private var modelPicker: some View {
        if loadingModels {
            ProgressView().controlSize(.small)
        } else if models.isEmpty {
            TextField("llama3.1:70b (manual)", text: $model).textFieldStyle(.roundedBorder)
        } else {
            Picker("", selection: $model) {
                ForEach(models, id: \.self) { m in Text(m).tag(m) }
            }
            .labelsHidden()
        }
    }

    // MARK: Step 3 — review + test
    private var doneView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("3. Review")

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Storage", storageMode == "remote" ? (apiBase.isEmpty ? "Remote (no URL)" : apiBase) : "This Mac")
                summaryRow("LLM endpoint", baseUrl.isEmpty ? "Not configured (read-through)" : baseUrl)
                if !baseUrl.isEmpty { summaryRow("Model", model.isEmpty ? "—" : model) }
            }

            HStack(spacing: 8) {
                if let r = testResult {
                    Label(r.message, systemImage: r.ok ? "checkmark.circle" : "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(r.ok ? Color.green : Color.red)
                }
                Spacer()
                Button("Test connection") { runTests() }
                    .disabled(testing || baseUrl.isEmpty)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func runTests() {
        testing = true
        testResult = nil
        let cfg = ServerConfig(apiBase: storageMode == "remote" ? apiBase.trimmingCharacters(in: .whitespaces) : "",
                               token: token)
        let llmConfig = LLMSettings(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces),
                                    apiKey: effectiveKey, model: model.trimmingCharacters(in: .whitespaces),
                                    keyEnv: keySource == .env ? selectedEnv : "")
        Task {
            var errors: [String] = []
            let storage = StorageFactory.make(config: cfg)
            if let ids = try? await storage.list() {
                _ = ids
            } else if storageMode == "remote" {
                errors.append("storage")
            }
            if !llmConfig.baseUrl.isEmpty {
                let pipe = LocalPipeline(baseUrl: llmConfig.baseUrl, apiKey: llmConfig.resolvedKey(), model: llmConfig.model)
                do {
                    let m = try await pipe.listModels()
                    if !m.contains(llmConfig.model) && llmConfig.model.isEmpty { _ = m }
                } catch {
                    errors.append("LLM")
                }
            }
            let ok = errors.isEmpty
            testResult = ok
                ? (true, "Both connections look good.")
                : (false, "Could not reach: \(errors.joined(separator: ", ")).")
            testing = false
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
        Task {
            let pipe = LocalPipeline(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces),
                                     apiKey: effectiveKey, model: model)
            if let ids = try? await pipe.listModels() {
                models = ids
                if !ids.contains(model) { model = ids.first ?? model }
            }
            loadingModels = false
        }
    }

    // MARK: footer
    private var footer: some View {
        HStack {
            if step == .storage || step == .llm {
                Button("Quit") { dismiss() }.buttonStyle(.borderless)
            }
            Spacer()
            if step != .storage { Button("Back") { back() }.buttonStyle(.borderless) }
            nextButton
        }
    }

    @ViewBuilder private var nextButton: some View {
        switch step {
        case .storage:
            Button("Continue") { step = .llm }.buttonStyle(.borderedProminent)
        case .llm:
            Button("Review") { step = .done }.buttonStyle(.borderedProminent)
        case .done:
            Button("Finish") { finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func back() {
        switch step {
        case .llm: step = .storage
        case .done: step = .llm
        default: break
        }
    }

    private func finish() {
        store.config = ServerConfig(apiBase: storageMode == "remote" ? apiBase.trimmingCharacters(in: .whitespaces) : "",
                                    token: token)
        store.llm = LLMSettings(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces),
                                apiKey: keySource == .manual ? manualKey.trimmingCharacters(in: .whitespaces) : "",
                                model: model.trimmingCharacters(in: .whitespaces),
                                keyEnv: keySource == .env ? selectedEnv : "")
        store.show("Setup complete")
        store.markOnboarded()
    }
}