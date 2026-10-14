import Foundation
import AppKit
import Combine
import FluidAudio
import PDFKit

@MainActor
final class AppStore: ObservableObject {
    /// Storage backend: local disk (self-host) or remote HTTP storage server.
    /// The pipeline always runs in-process; this only decides where files live.
    @Published var config = ServerConfig.load() { didSet { config.save() } }

    private var storage: Storage {
        StorageFactory.make(config: config)
    }
    var isStandalone: Bool { config.apiBase.isEmpty }

    /// Reveal the paper's folder in Finder (local storage only).
    func revealInFinder(_ id: String) {
        guard isStandalone else { return }
        Task {
            if let u = await storage.url(for: K.paper(id)) {
                NSWorkspace.shared.activateFileViewerSelecting([u])
            }
        }
    }

    @Published var papers: [String: Paper] = [:]
    @Published var selectedId: String?
    /// Global audio player shown in the bottom status bar (iTunes-style).
    @Published var player: PlayerController
    /// The paper whose audio the global player currently holds.
    @Published var playingPaperId: String?
    /// Paper currently open in the metadata edit sheet.
    @Published var editingPaper: Paper?

    // filtering
    @Published var view: ViewMode = .all
    @Published var activeTag: String?
    /// Library presentation: thumbnail grid or compact list.
    @Published var libraryLayout: LibraryLayout = .grid
    @Published var search = ""
    @Published var sort: SortOption = .newest
    @Published var statusFilter: String = "all"

    /// LLM endpoint the in-process pipeline uses. Stored locally.
    @Published var llm = LLMSettings.load() { didSet { llm.save() } }

    /// Editable LLM prose prompts. Stored locally.
    @Published var prompts = PromptSettings.load() { didSet { prompts.save() } }

    @Published var toast: String?
    /// True while the first-run setup wizard should be shown.
    @Published var showOnboarding = false
    /// In-memory cache of rendered first-page PDF thumbnails.
    private var thumbCache: [String: NSImage] = [:]
    /// Raw activity log shown in the bottom pane; newest last.
    @Published var logLines: [String] = []
    private static let logFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    func appendLog(_ line: String) {
        logLines.append("[\(Self.logFmt.string(from: Date()))] \(line)")
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    enum SettingsPage: Int, Identifiable {
        case llm, server, prompts, clear
        var id: Int { rawValue }
    }
    /// Whether the unified settings sheet is open.
    @Published var showSettings = false
    /// The settings page to show once open.
    @Published var settingsPage: SettingsPage = .llm

    private var toastTask: Task<Void, Never>?
    private var playbackCancelables: Set<AnyCancellable> = []

    enum ViewMode { case all, fav, tag }

    init() {
        player = PlayerController()
        Self.migrateDefaults()
        refresh()
        showOnboarding = !Self.didOnboard()
    }

    /// Copy settings saved under the old "paper2pod.*" keys to the renamed
    /// "papertalk.*" keys once, so config from previous builds isn't lost.
    private static func migrateDefaults() {
        let d = UserDefaults.standard
        let pairs = [
            ("paper2pod.onboarded", "papertalk.onboarded"),
            ("paper2pod.server.json", "papertalk.server.json"),
            ("paper2pod.llm.json", "papertalk.llm.json"),
        ]
        for (old, new) in pairs {
            if d.object(forKey: new) == nil, let v = d.object(forKey: old) {
                d.set(v, forKey: new)
            }
        }
    }

    /// Whether the user has completed (or dismissed) the first-run setup wizard.
    static func didOnboard() -> Bool {
        UserDefaults.standard.bool(forKey: "papertalk.onboarded")
    }
    func markOnboarded() {
        UserDefaults.standard.set(true, forKey: "papertalk.onboarded")
        showOnboarding = false
    }

    /// Renders the first page of a stored PDF as a cached thumbnail, or nil when
    /// the PDF is missing/unreadable (caller falls back to a placeholder).
    func loadThumbnail(_ id: String) async -> NSImage? {
        if let cached = thumbCache[id] { return cached }
        guard let data = try? await storage.read(K.pdf(id)),
              let image = Self.thumbnail(of: data) else { return nil }
        thumbCache[id] = image
        return image
    }

    private static func thumbnail(of data: Data, width: CGFloat = 280) -> NSImage? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let height = width * bounds.height / bounds.width
        let size = NSSize(width: width, height: height)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: size).fill()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.scaleBy(x: width / bounds.width, y: height / bounds.height)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        img.unlockFocus()
        return img
    }

    /// The raw bytes of a paper's stored PDF, or nil.
    func pdfData(for id: String) async -> Data? {
        try? await storage.read(K.pdf(id))
    }

    // MARK: Sorting / filtering helpers
    var allPapers: [Paper] { Array(papers.values) }

    func filteredPapers() -> [Paper] {
        var out = Array(papers.values)
        switch view {
        case .fav: out = out.filter { $0.favorite }
        case .tag: if let t = activeTag { out = out.filter { $0.tags.contains(t) } }
        case .all: break
        }
        if statusFilter != "all" { out = out.filter { $0.state == statusFilter } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter {
                [$0.title ?? "", $0.filename ?? "", $0.tags.joined(separator: " ")]
                    .joined(separator: " ").lowercased().contains(q)
            }
        }
        switch sort {
        case .title: out.sort { ($0.title ?? $0.filename ?? "").localizedCompare($1.title ?? $1.filename ?? "") == .orderedAscending }
        case .oldest: out.sort { ($0.createdIso ?? "") < ($1.createdIso ?? "") }
        case .recent:
            out.sort { a, b in
                let aDone = a.isDone || a.hasAudio ? 1 : 0
                let bDone = b.isDone || b.hasAudio ? 1 : 0
                if aDone != bDone { return aDone > bDone }
                return (b.createdIso ?? "") < (a.createdIso ?? "")
            }
        case .newest: out.sort { ($0.createdIso ?? "") > ($1.createdIso ?? "") }
        }
        return out
    }

    func selectedPaper() -> Paper? { selectedId.flatMap { papers[$0] } }

    /// The single paper currently being imported/regenerated, if any. Only one
    /// job runs at a time, so this drives the bottom status bar's progress.
    var activeRun: Paper? {
        papers.values.first { $0.state == "running" }
    }

    var tagCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for p in papers.values {
            for t in Set(p.tags) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
    }

    // MARK: Artifact access (all via the active storage)
    func transcript(for id: String) async -> Transcript? {
        await storage.exists(Transcript.self, K.transcript(id))
    }

    /// Audio is always synthesized live from the transcript (AVSpeechSynthesizer),
    /// so there is no baked audio URL to fetch.
    func audioURL(for p: Paper) -> URL? { nil }

    func url(for key: String) async -> URL? {
        await storage.url(for: key)
    }

    // MARK: Library
    func refresh() {
        Task {
            let ids = (try? await storage.list()) ?? []
            var seen = Set(ids)
            for id in ids {
                if papers[id] == nil, let p: Paper = await storage.exists(Paper.self, K.paper(id)) {
                    papers[id] = p
                }
            }
            for id in Array(papers.keys) where !seen.contains(id) {
                if selectedId == id { selectedId = nil }
                papers.removeValue(forKey: id)
            }
        }
    }

    // MARK: Metadata mutations
    private func optimistic(_ id: String, _ mutate: (inout Paper) -> Void) {
        guard var p = papers[id] else { return }
        mutate(&p)
        papers[id] = p
        Task { await storage.save(p, K.paper(id)) }
    }
    func toggleFavorite(_ id: String) {
        optimistic(id, { $0.favorite.toggle() })
    }
    func toggleRead(_ id: String, force: Bool? = nil) {
        optimistic(id, { $0.read = force ?? !$0.read })
    }
    func saveTitle(_ id: String, _ title: String) {
        let clean = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { toast = "Title cannot be empty"; return }
        guard clean != (papers[id]?.title ?? "") else { return }
        optimistic(id, { $0.title = clean })
    }
    func addTag(_ id: String, _ tag: String) {
        let clean = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
        guard !clean.isEmpty, let p = papers[id], !p.tags.contains(clean) else { return }
        optimistic(id, { $0.tags = $0.tags + [clean] })
    }
    func removeTag(_ id: String, _ tag: String) {
        guard let p = papers[id] else { return }
        let next = p.tags.filter { $0 != tag }
        guard next.count != p.tags.count else { return }
        optimistic(id, { $0.tags = next })
    }
    func saveProgress(_ id: String, _ progress: Double, _ duration: Double) {
        guard var p = papers[id] else { return }
        p.progress = progress
        p.duration = duration
        papers[id] = p
        Task { await storage.save(p, K.paper(id)) }
    }
    func saveEditableMeta(_ id: String, title: String, filename: String, authors: [String], affiliations: [String], doi: String) {
        let split: (String) -> [String] = { $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        guard var p = papers[id] else { return }
        p.title = title.trimmingCharacters(in: .whitespaces)
        p.filename = filename.trimmingCharacters(in: .whitespaces)
        p.authors = split(authors.joined(separator: "\n"))
        p.affiliations = split(affiliations.joined(separator: "\n"))
        p.doi = doi.trimmingCharacters(in: .whitespaces)
        papers[id] = p
        Task { await storage.save(p, K.paper(id)) }
    }

    // MARK: Actions
    func rerun(_ id: String) {
        let p = papers[id]
        let depth = p.flatMap { Depth(rawValue: $0.depth ?? "") } ?? .inDepth
        Task { await runPipeline(papers[id], depth: depth) }
    }
    func resetError(_ id: String) {
        guard let p = papers[id] else { return }
        papers[id] = p.revertingError()
    }
    func delete(_ id: String) {
        Task {
            do {
                for key in [K.paper(id), K.script(id), K.transcript(id), K.captions(id), K.pdf(id), K.audio(id)] {
                    try await storage.delete(key)
                }
                await deleteBakedAudio(id)
                if selectedId == id { selectedId = nil }
                papers.removeValue(forKey: id)
            } catch { toast = "Delete failed: \(error.localizedDescription)" }
        }
    }

    /// Remove a paper's baked per-turn WAVs + manifest (best-effort).
    private func deleteBakedAudio(_ id: String) async {
        if let manifest = await storage.exists(AudioManifest.self, K.audioManifest(id)) {
            for i in manifest.durations.indices {
                try? await storage.delete(K.turn(id, i))
            }
        }
        try? await storage.delete(K.audioManifest(id))
    }

    /// Wipe everything: library data, all app settings, and caches (Kokoro
    /// model cache + in-memory thumbnail log). Resets the store to a fresh state.
    func clearAll() {
        Task {
            // 1. Library data (deleted best-effort, one paper at a time).
            for id in papers.keys {
                for key in [K.paper(id), K.script(id), K.transcript(id), K.captions(id), K.pdf(id), K.audio(id)] {
                    try? await storage.delete(key)
                }
                await deleteBakedAudio(id)
            }
            papers.removeAll()
            thumbCache.removeAll()
            selectedId = nil
            logLines = []
            // 2. All settings + old (pre-rename) keys.
            let d = UserDefaults.standard
            for key in ["papertalk.server.json", "papertalk.llm.json", "papertalk.prompts.json", "papertalk.settingsPage", "papertalk.onboarded",
                        "paper2pod.server.json", "paper2pod.llm.json", "paper2pod.onboarded"] {
                d.removeObject(forKey: key)
            }
            // 3. Kokoro model cache download dir, if present.
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let audio = caches.appendingPathComponent("fluidaudio", isDirectory: true)
                try? FileManager.default.removeItem(at: audio)
            }
            // 4. Back to a clean reactive state.
            config = ServerConfig.load()   // save() re-persists env defaults
            llm = LLMSettings.load()
            toast = "Cleared data, settings and cache"
        }
    }
    func refreshMeta(_ id: String) {
        Task {
            appendLog("Extracting metadata with LLM…")
            guard let pdfData = try? await storage.read(K.pdf(id)) else {
                appendLog("ERROR: no PDF on disk to extract metadata from"); toast = "No PDF to read"; return
            }
            let text = LocalPipeline.extractText(pdfData)
            guard !text.isEmpty else { toast = "Could not read PDF text"; return }
            applyMetaFromLLM(id, text: text, fallback: papers[id]?.displayTitle ?? "Untitled")
        }
    }

    /// (Re)extract title/authors/affiliations/DOI/tags via the LLM and merge into
    /// the paper only for fields that are empty, keeping hand-edited values.
    private func applyMetaFromLLM(_ id: String, text: String, fallback: String) {
        Task {
            do {
                let base = llm.baseUrl
                guard !base.isEmpty else { toast = "Configure an LLM to extract metadata"; return }
                let p = LocalPipeline(baseUrl: base, apiKey: llm.resolvedKey(), model: llm.model.isEmpty ? "llama3.1:70b" : llm.model)
                var pipeline = p
                pipeline.prompts = prompts
                pipeline.log = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
                let meta = try await pipeline.extractMeta(text: text, fallbackTitle: fallback)
                optimistic(id, {
                    if ($0.title ?? "").isEmpty { $0.title = meta.title }
                    if $0.authors.isEmpty { $0.authors = meta.authors }
                    if $0.affiliations.isEmpty { $0.affiliations = meta.affiliations }
                    if $0.doi.isEmpty { $0.doi = meta.doi }
                    if $0.tags.isEmpty { $0.tags = meta.tags }
                })
                appendLog("Metadata: \(meta.authors.joined(separator: ", ")) · \(meta.tags.joined(separator: ", "))")
            } catch {
                appendLog("WARN: metadata extraction failed: \(error.localizedDescription)")
            }
        }
    }

    /// Run the in-process pipeline on a PDF (or an existing stored paper).
    func upload(_ pdf: Data, filename: String, depth: Depth, depthNote: String) {
        toast = "Uploading…"
        Task { await runPipeline(nil, pdf: pdf, filename: filename, depth: depth, depthNote: depthNote); toast = "Upload started" }
    }

    // MARK: Audio baking

    /// Render a transcript to per-turn WAVs with Kokoro and store them under
    /// the paper's `turns/` keys. Reports download + per-turn progress across
    /// the given [start, end] band of the unified pipeline bar. Returns true on
    /// success (hasAudio = true).
    private func bakeAudio(_ id: String, _ transcript: Transcript, from start: Double, to end: Double) async -> Bool {
        let flat = transcript.segments.flatMap { $0.turns }
        guard !flat.isEmpty else { return false }
        let total = flat.count
        func map(_ f: Double) -> Double { start + (end - start) * f }
        updateRec(id) { $0.stage = "audio"; $0.progress = map(0.0); $0.message = "Preparing Kokoro…" }

        let manager = KokoroAneManager(variant: .english)
        do {
            // Warm the model cache with download progress (single bar). No-op
            // when models already cached, but still reports journal progress.
            try await KokoroAneResourceDownloader.ensureModels(variant: .english) { [weak self] p in
                let phase: String = {
                    switch p.phase {
                    case .listing: return "Contacting model server…"
                    case .downloading: return "Downloading Kokoro model…"
                    case .compiling: return "Compiling Kokoro model…"
                    }
                }()
                Task { @MainActor in
                    self?.updateRec(id) {
                        $0.stage = "audio"
                        // Download occupies the first half of the bake band.
                        $0.progress = map(p.fractionCompleted * 0.5)
                        $0.message = phase
                    }
                }
            }
            try await manager.initialize()

            var durations: [Double] = []
            let voiceMap = KokoroSpeech.voices(for: flat.map { $0.speaker })
            for (i, turn) in flat.enumerated() {
                if Task.isCancelled { return false }
                let wav = try await manager.synthesize(text: turn.text, voice: voiceMap[turn.speaker] ?? KokoroSpeech.defaultVoice, speed: 0.95)
                try await storage.write(K.turn(id, i), wav)
                durations.append(KokoroSpeech.wavDuration(wav))
                let frac = 0.5 + 0.5 * Double(i + 1) / Double(total)
                updateRec(id) { $0.stage = "audio"; $0.progress = map(frac); $0.message = "Synthesizing section \(i + 1)/\(total)…" }
            }
            await storage.save(AudioManifest(durations: durations), K.audioManifest(id))
            return true
        } catch {
            appendLog("Audio synthesis failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Load a baked episode's per-turn WAVs for playback, or nil if not baked.
    func loadBakedAudio(for id: String) async -> [BakedTurn]? {
        guard let manifest = await storage.exists(AudioManifest.self, K.audioManifest(id)) else { return nil }
        var turns: [BakedTurn] = []
        for (i, dur) in manifest.durations.enumerated() {
            guard let wav = try? await storage.read(K.turn(id, i)) else { return nil }
            turns.append(BakedTurn(wav: wav, duration: dur))
        }
        return turns
    }

    /// Point the global player at a paper: baked audio when present, else a live
    /// render of its transcript. Async so the caller can await readiness.
    func prepareAudio(for id: String) async {
        playingPaperId = id
        guard let t = await transcript(for: id) else { player.stopAll(); return }
        if let baked = await loadBakedAudio(for: id), !baked.isEmpty {
            player.prepare(baked: baked)
        } else {
            player.prepare(transcript: t)
        }
    }

    /// Wire playback-position persistence once at startup. Uses the global
    /// `playingPaperId` as the target paper, so it follows whatever is loaded.
    func trackPlayback() {
        player.$didEnd
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, let id = self.playingPaperId else { return }
                    self.saveProgress(id, 0, self.player.duration)
                    if let p = self.papers[id], !p.read { self.toggleRead(id, force: true) }
                }
            }
            .store(in: &playbackCancelables)
        player.$currentTime
            .filter { [weak self] _ in self?.player.isPlaying == true }
            .filter { $0 > 0 }
            .filter { $0.truncatingRemainder(dividingBy: 10) < 0.4 }
            .sink { [weak self] t in
                Task { @MainActor in
                    guard let self, let id = self.playingPaperId else { return }
                    self.saveProgress(id, t, self.player.duration)
                }
            }
            .store(in: &playbackCancelables)
    }

    /// Re-synthesize a paper's audio from its stored transcript (no LLM re-run).
    /// Uses the same progress bar as import, then reloads the global player.
    func regenerateAudio(_ id: String) {
        guard let p = papers[id], p.hasScript else { toast = "No transcript to speak"; return }
        Task {
            guard let t = await transcript(for: id) else { toast = "No transcript on disk"; return }
            appendLog("Regenerating audio for \(p.displayTitle)…")
            updateRec(id) { $0.state = "running"; $0.stage = "audio"; $0.progress = 0.02; $0.message = "Preparing Kokoro…" }
            let baked = await bakeAudio(id, t, from: 0.0, to: 1.0)
            if baked {
                updateRec(id) { $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = "Done"; $0.hasAudio = true }
                appendLog("Audio regenerated.")
                toast = "Audio regenerated"
                await prepareAudio(for: id)
            } else {
                updateRec(id) { $0.state = "error"; $0.stage = "audio"; $0.statusError = "Audio synthesis failed" }
                appendLog("ERROR: audio regeneration failed")
            }
        }
    }

    // MARK: Pipeline (always local)
    private func runPipeline(_ existing: Paper?, pdf: Data? = nil, filename: String = "", depth: Depth = .inDepth, depthNote: String = "") async {
        let id = existing?.id ?? UUID().uuidString
        let name = filename.isEmpty ? (existing?.filename ?? "Paper") : filename

        var rec = existing ?? Paper(id: id, title: "", filename: name, hasPdf: true, hasScript: false, hasAudio: false,
                                     createdIso: ISO8601DateFormatter().string(from: Date()), state: "queued",
                                     tags: [], favorite: false, authors: [], affiliations: [], doi: "", read: false,
                                     depth: existing?.depth ?? "in_depth", progress: 0, duration: 0, progressTs: nil,
                                     stage: "extract", message: "Queued", statusError: nil)
        papers[id] = rec
        selectedId = id
        appendLog("Queued: \(name)")

        let base = llm.baseUrl
        let key = llm.resolvedKey()
        let model = llm.model.isEmpty ? "llama3.1:70b" : llm.model

        let pdfData: Data
        if let pdf {
            pdfData = pdf
        } else if let stored = try? await storage.read(K.pdf(id)) {
            pdfData = stored
        } else {
            updateRec(id) { $0.state = "error"; $0.statusError = "No PDF" }; appendLog("ERROR: No PDF to convert"); return
        }
        var pipeline = LocalPipeline(baseUrl: base, apiKey: key, model: model)
        pipeline.prompts = prompts
        pipeline.log = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        // Transcript writing spans 0.10 → 0.75 of the unified pipeline bar.
        pipeline.onProgress = { [weak self] frac, label in
            Task { @MainActor in self?.updateRec(id) { $0.progress = 0.10 + 0.65 * frac; $0.message = label } }
        }

        updateRec(id) { $0.state = "running"; $0.stage = "extract"; $0.progress = 0.02; $0.message = "Extracting text…" }
        appendLog("Extracting PDF text…")
        let text = LocalPipeline.extractText(pdfData)
        guard !text.isEmpty else {
            updateRec(id) { $0.state = "error"; $0.statusError = "Could not read PDF text" }; appendLog("ERROR: Could not read PDF text"); return
        }
        appendLog("Extracted \(text.count) characters")
        try? await storage.write(K.pdf(id), pdfData)

        // Fill title/authors/DOI/tags from the LLM right away (before the script),
        // so the detail view shows real metadata even while the episode is being written.
        if !base.isEmpty {
            applyMetaFromLLM(id, text: text, fallback: name)
        }

        guard !base.isEmpty else {
            // no LLM configured: fall back to a read-through transcript
            appendLog("No LLM URL configured — using read-through transcript")
            let fallback = Transcript(paperTitle: name, speakers: [Transcript.Speaker(name: "Reader", persona: "")],
                                      segments: [Transcript.Segment(title: "Paper", turns: text.prefix(8000).split(separator: "\n")
                                          .map { String($0) }.filter { !$0.isEmpty }.map { Transcript.Turn(speaker: "Reader", text: $0) })] )
            await finish(id, fallback, name, authors: [], pdfData: pdfData, hasAudio: false)
            return
        }

        updateRec(id) { $0.state = "running"; $0.stage = "segments"; $0.progress = 0.08; $0.message = "Planning episode…" }
        appendLog("Calling \(model) @ \(base)…")
        do {
            let result = try await pipeline.generateTranscript(text: text, depth: depth, depthNote: depthNote)
            appendLog("Got transcript (\(result.transcript.segments.count) segments)")
            updateRec(id) { $0.stage = "audio"; $0.progress = 0.78; $0.message = "Synthesizing audio…" }
            let baked = await bakeAudio(id, result.transcript, from: 0.80, to: 1.0)
            await finish(id, result.transcript, result.title.isEmpty ? name : result.title,
                         authors: result.authors, pdfData: pdfData, depth: depth, hasAudio: baked)
        } catch {
            updateRec(id) { $0.state = "error"; $0.statusError = error.localizedDescription }
            appendLog("ERROR: \(error.localizedDescription)")
            toast = "Conversion failed: \(error.localizedDescription)"
        }
    }

    private func finish(_ id: String, _ t: Transcript, _ title: String, authors: [String], pdfData: Data?, depth: Depth = .inDepth, hasAudio: Bool) async {
        await storage.save(t, K.transcript(id))
        try? await storage.write(K.pdf(id), pdfData ?? Data())
        updateRec(id) {
            $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = "Done"
            $0.hasScript = true; $0.hasAudio = hasAudio
            $0.title = $0.title ?? title
            $0.authors = authors.isEmpty ? $0.authors : authors
            $0.depth = depth.rawValue
        }
        appendLog("Done: \(title)")
        toast = "Converted"
    }

    private func updateRec(_ id: String, _ mutate: (inout Paper) -> Void) {
        guard var p = papers[id] else { return }
        mutate(&p)
        papers[id] = p
    }

    func show(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func select(_ id: String?) { selectedId = id }

    /// Load the selected paper's audio into the global player (once), so the
    /// bottom bar is ready to play as soon as a paper is clicked.
    func loadAudioForSelected() async {
        guard let id = selectedId else { player.stopAll(); playingPaperId = nil; return }
        guard playingPaperId != id else { return }
        await prepareAudio(for: id)
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case newest, oldest, title = "Title", recent = "Recently converted"
    var id: String { rawValue }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid = "Grid", list = "List"
    var id: String { rawValue }
}