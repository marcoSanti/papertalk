#if os(macOS)
import SwiftUI

// MARK: - First-run setup wizard: storage backend + LLM endpoint.
struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore

    @State private var step: SetupStep = .storage
    @State private var server = ServerSettingsForm(ServerConfig(apiBase: "", token: ""))
    @State private var llm = LLMSettingsForm(LLMSettings(baseUrl: "", apiKey: "", model: "", keyEnv: ""))
    @State private var speech = SpeechSettingsForm(SpeechSettings())
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            Group {
                switch step {
                case .storage: storageView
                case .llm: llmView
                case .voices: voicesView
                case .review: reviewView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 500, height: 640)
        .tint(Color.appAccent)
        .onChange(of: llm.keySource) { _, _ in llm.keySourceChanged() }
        .onAppear {
            server = ServerSettingsForm(store.config)
            llm = LLMSettingsForm(store.llm)
            speech = SpeechSettingsForm(store.speech)
            if llm.canFetchModels { loadModels() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 28)).foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Welcome to Papertalk")).font(.title2).fontWeight(.semibold)
                Text(L("Set up where your papers live, which LLM writes the episodes, and where the voices are made.")).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            LanguagePicker()
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help(LanguagePresentation.pickerLabel)
        }
    }

    private func stepTitle(_ t: String) -> some View {
        Text(t).font(.headline)
    }

    // MARK: Step 1 — storage
    private var storageView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L("1. Where should your library be stored?"))
            HStack(spacing: 10) {
                storageCard(.local, icon: "internaldrive", title: L("On this Mac"),
                            desc: L("Files kept locally in Application Support."))
                storageCard(.remote, icon: "network", title: L("Storage server"),
                            desc: L("Point at your storage_server.py (HTTP)."))
            }
            if server.mode == .remote {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Storage server URL")).font(.caption)
                    TextField("http://host:9170", text: $server.apiBase).textFieldStyle(.roundedBorder)
                    Text(L("API token")).font(.caption)
                    SecureField(L("token (optional)"), text: $server.token).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func storageCard(_ mode: ServerSettingsForm.Mode, icon: String, title: String, desc: String) -> some View {
        let selected = server.mode == mode
        return Button {
            server.mode = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? Color.appAccent : Color.secondary)
                    Spacer()
                }
                Text(title).font(.callout).fontWeight(.semibold)
                Text(desc).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.appAccent.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.appAccent : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.borderless)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Step 2 — LLM
    private var llmView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L("2. Which LLM writes the episodes?"))
            Text(L("An OpenAI-compatible chat endpoint. Leave empty to use a plain read-through transcript (no AI)."))
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("LLM base URL")).font(.caption)
                TextField("http://localhost:3000/api", text: $llm.baseUrl).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("API key source")).font(.caption)
                Picker("", selection: $llm.keySource) {
                    ForEach(LLMKeySource.allCases) { s in Text(s.label).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            KeySourceFields(form: $llm)
            HStack {
                Text(L("Model")).font(.caption)
                Spacer()
                Button(loadingModels ? L("Loading…") : L("Refresh models")) { loadModels() }
                    .disabled(loadingModels || !llm.canFetchModels)
            }
            modelPicker
        }
    }

    @ViewBuilder private var modelPicker: some View {
        if loadingModels {
            ProgressView().controlSize(.small)
        } else if models.isEmpty {
            TextField(L("llama3.1:70b (manual)"), text: $llm.model).textFieldStyle(.roundedBorder)
        } else {
            Picker("", selection: $llm.model) {
                ForEach(models, id: \.self) { m in Text(m).tag(m) }
            }
            .labelsHidden()
        }
    }

    // MARK: Step 3 — voices
    private var voicesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L("3. Where should the voices be synthesized?"))
            ScrollView { SpeechSettingsFields(form: $speech).padding(.trailing, 8) }
        }
    }

    // MARK: Step 4 — review + test
    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L("4. Review"))

            VStack(alignment: .leading, spacing: 6) {
                summaryRow(L("Storage"), server.summary)
                ForEach(SetupStep.llmSummary(llm.settings), id: \.label) { row in
                    summaryRow(row.label, row.value)
                }
                ForEach(speech.summary, id: \.label) { row in
                    summaryRow(row.label, row.value)
                }
            }

            HStack(spacing: 8) {
                if let r = testResult {
                    Label(r.message, systemImage: r.ok ? "checkmark.circle" : "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(r.ok ? Color.green : Color.red)
                }
                Spacer()
                Button(L("Test connection")) { runTests() }
                    .disabled(testing || !llm.canFetchModels)
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
        Task {
            let settings = llm.settings
            testResult = await store.checkConnections(server: server.config, llmBaseURL: settings.baseUrl,
                                                      apiKey: llm.effectiveKey(), model: settings.model)
            testing = false
        }
    }

    private func loadModels() {
        loadingModels = true
        Task {
            if let ids = try? await llm.fetchModels() {
                models = ids
                _ = llm.applyModels(ids)
            }
            loadingModels = false
        }
    }

    // MARK: footer
    private var footer: some View {
        HStack {
            if step.canSkip {
                Button(L("Skip setup")) { store.markOnboarded() }
                    .buttonStyle(.borderless)
                    .help(L("Use the defaults for now; change them any time in Settings (⌘,)"))
            }
            Spacer()
            if let previous = step.previous {
                Button(L("Back")) { step = previous }.buttonStyle(.borderless)
            }
            Button(step.nextTitle) {
                if let next = step.next { step = next } else { store.finishSetup(server: server.config, llm: llm.settings, speech: speech.settings) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(step.next == nil ? .defaultAction : nil)
        }
    }
}

#endif
