import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif
#if canImport(PDFKit)
import PDFKit
#endif

@MainActor
final class AppStore: ObservableObject {
    /// Storage backend: local disk (self-host) or remote HTTP storage server.
    /// The pipeline always runs in-process; this only decides where files live.
    @Published var config = ServerConfig.load() { didSet { config.save() } }

    private var storage: Storage {
        storageOverride ?? StorageFactory.make(config: config)
    }
    /// Fixed backend for tests, so they never touch the real library.
    private let storageOverride: Storage?
    var isStandalone: Bool {
        if let storageOverride { return storageOverride is LocalStorage }
        return config.apiBase.isEmpty
    }

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
    /// Which of the active imports the bottom bar is focused on.
    @Published var activeRunIndex = 0
    /// Paper currently open in the metadata edit sheet.
    @Published var editingPaper: Paper?
    /// Whether the import sheet is open, and a file to pre-load into it
    /// (set when a PDF is dropped on the library).
    @Published var showUpload = false
    @Published var pendingUploadURL: URL?
    func beginImport(_ url: URL? = nil) {
        pendingUploadURL = url
        showUpload = true
    }
    /// Destructive action awaiting confirmation. Lives on the store so the
    /// dialog survives the context menu that asked for it being torn down.
    @Published var pendingConfirmation: PendingConfirmation?
    // MARK: Settings

    /// Save the storage server settings (only when they changed).
    func saveServerSettings(_ next: ServerConfig) {
        if next != config { config = next }
    }

    /// Save the LLM settings (only when they changed); an env-sourced key is
    /// copied to the Keychain for apps launched from Finder.
    func saveLLMSettings(_ next: LLMSettings) {
        guard next != llm else { return }
        llm = next
        llm.saveResolvedKey()
    }

    /// Save where voices are synthesized (only when it changed).
    func saveSpeechSettings(_ next: SpeechSettings) {
        if next != speech { speech = next }
    }

    /// Save the edited LLM prompts (only when they changed).
    func savePrompts(_ next: PromptSettings) {
        if next != prompts { prompts = next }
    }

    /// Save the custom-depth presets (already cleaned by `PresetsForm`).
    func savePresets(_ entries: [CustomDepthPresets.Entry]) {
        customPresets = CustomDepthPresets(entries: entries)
        customPresets.save()
    }

    /// Setup wizard: check that the storage server (if any) and the LLM answer.
    func checkConnections(server: ServerConfig, llmBaseURL: String, apiKey: String, model: String) async -> (ok: Bool, message: String) {
        var failures: [String] = []
        if !server.apiBase.isEmpty, (try? await StorageFactory.make(config: server).list()) == nil {
            failures.append("storage")
        }
        if !llmBaseURL.isEmpty,
           (try? await LocalPipeline(baseUrl: llmBaseURL, apiKey: apiKey, model: model).listModels()) == nil {
            failures.append("LLM")
        }
        return failures.isEmpty
            ? (true, "Both connections look good.")
            : (false, "Could not reach: \(failures.joined(separator: ", ")).")
    }

    /// Setup wizard: save everything and close it.
    func finishSetup(server: ServerConfig, llm next: LLMSettings, speech voices: SpeechSettings) {
        config = server
        llm = next
        llm.saveResolvedKey()
        saveSpeechSettings(voices)
        show("Setup complete")
        markOnboarded()
    }

    /// Rerun from a menu or button: confirm first when it would replace an episode.
    func requestRerun(_ p: Paper) {
        if PaperPresentation.rerunNeedsConfirmation(p) { pendingConfirmation = .rerun(p) } else { rerun(p.id) }
    }

    /// Rename from the inline title field. Returns the text the field should
    /// show: the tidied title, or the current one if the edit was empty.
    @discardableResult
    func commitTitleEdit(_ id: String, draft: String) -> String {
        let current = papers[id]?.displayTitle ?? ""
        guard let edit = PaperPresentation.titleEdit(draft, current: current) else { return current }
        if edit.changed { saveTitle(id, edit.clean) }
        return edit.clean
    }

    /// Carry out a confirmed destructive action.
    func confirmPending(_ pending: PendingConfirmation) {
        pendingConfirmation = nil
        switch pending {
        case .delete(let p): delete(p.id)
        case .rerun(let p): rerun(p.id)
        }
    }
    enum PendingConfirmation: Identifiable {
        case delete(Paper), rerun(Paper)
        var id: String {
            switch self {
            case .delete(let p): return "delete-\(p.id)"
            case .rerun(let p): return "rerun-\(p.id)"
            }
        }
    }
    /// Pending "already in library" prompt whose answer is awaited by the
    /// import pipeline. Lives on the store so it survives sheet dismissal.
    struct DuplicatePrompt {
        let incoming: Paper
        let duplicateOf: Paper
        let cont: CheckedContinuation<Bool, Never>
    }
    @Published var pendingDuplicate: DuplicatePrompt?

    /// Pending cast-selection prompt (shown once the model has proposed names
    /// and genders). The import pipeline waits on its continuation; resuming
    /// with nil means "cancel the whole import".
    struct CastPrompt {
        let paperId: String
        let paperTitle: String
        let proposals: [ProposedSpeaker]
        let authors: [String]
        let authorGenders: [String: String]
        let cont: CheckedContinuation<[SpeakerConfig]?, Never>
    }
    @Published var pendingCast: CastPrompt?
    /// System notifications while the app is in the background.
    let notifier = Notifier()
    /// Papers are voiced one at a time: concurrent bakes ran small Macs out of memory.
    let audioGate = SerialGate()

    // filtering
    @Published var view: ViewMode = .all
    @Published var activeTag: String?
    @Published var activeAuthor: String?
    /// Named custom-depth prompts, selectable from the upload sheet's dropdown.
    @Published var customPresets: CustomDepthPresets = .load()
    /// Library presentation: thumbnail grid or compact list.
    @Published var libraryLayout: LibraryLayout = .grid
    @Published var search = ""
    @Published var sort: SortOption = .newest
    @Published var statusFilter: String = "all"

    /// LLM endpoint the in-process pipeline uses. Stored locally.
    @Published var llm = LLMSettings.load() { didSet { llm.save() } }

    /// Where voices are synthesized (this machine or a speech server). Stored locally.
    @Published var speech: SpeechSettings {
        didSet {
            speech.save()
            player.speechBackend = speechBackend
        }
    }
    /// Fixed speech backend for tests, so they never reach Kokoro.
    private let speechOverride: (any SpeechBackend)?
    /// The backend every synthesis path uses: baking, live playback, samples.
    var speechBackend: any SpeechBackend { speechOverride ?? speech.makeBackend() }

    /// Editable LLM prose prompts. Stored locally.
    @Published var prompts = PromptSettings.load() { didSet { prompts.save() } }

    @Published private(set) var toast: String?
    /// True while the first-run setup wizard should be shown.
    @Published var showOnboarding = false
    /// In-memory cache of rendered first-page PDF thumbnails.
    private var thumbCache: [String: NSImage] = [:]
    /// Bumped whenever a paper's PDF is (re)written, so covers that were
    /// asked for before the file existed load again.
    @Published private(set) var artworkRevision: [String: Int] = [:]
    private func pdfStored(_ id: String) {
        thumbCache[id] = nil
        artworkRevision[id, default: 0] += 1
    }
    /// Activity log, newest last. Each line remembers which paper it's about
    /// so the inspector can show just that paper's activity.
    struct LogEntry { let paperId: String?; let text: String }
    @Published private(set) var logEntries: [LogEntry] = []
    private static let logFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    func appendLog(_ line: String, paper id: String? = nil) {
        logEntries.append(LogEntry(paperId: id, text: "[\(Self.logFmt.string(from: Date()))] \(line)"))
        if logEntries.count > 2000 { logEntries.removeFirst(logEntries.count - 2000) }
    }
    func logLines(for id: String) -> [String] {
        logEntries.filter { $0.paperId == id }.map(\.text)
    }

    /// Raw values are remembered between launches: add new pages at the end.
    enum SettingsPage: Int, Identifiable {
        case llm, server, prompts, presets, clear, voices
        var id: Int { rawValue }
    }
    /// Whether the unified settings sheet is open.
    @Published var showSettings = false
    /// The settings page to show once open.
    @Published var settingsPage: SettingsPage = .llm

    private var toastTask: Task<Void, Never>?
    private var playbackCancelables: Set<AnyCancellable> = []

    enum ViewMode { case all, fav, authors, tag, author }

    /// `storage` pins the backend (tests pass a temp-folder `LocalStorage`);
    /// the app passes nothing and follows the configured server. `speech`
    /// likewise pins the speech backend, else the saved settings pick it.
    init(storage: Storage? = nil, speech backend: (any SpeechBackend)? = nil) {
        storageOverride = storage
        speechOverride = backend
        let settings = SpeechSettings.load()
        speech = settings
        player = PlayerController(speechBackend: backend ?? settings.makeBackend())
        notifier.onOpen = { [weak self] id in self?.reveal(id) }
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
        #if os(Linux)
        return PDFDocument.coverPNG(of: data, width: width * 2).map(NSImage.init(png:))
        #else
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale: CGFloat = 2
        let w = Int(width * scale), h = Int(width * scale * bounds.height / bounds.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / bounds.width, y: CGFloat(h) / bounds.height)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: width * bounds.height / bounds.width))
        #endif
    }

    /// The raw bytes of a paper's stored PDF, or nil.
    func pdfData(for id: String) async -> Data? {
        try? await storage.read(K.pdf(id))
    }

    // MARK: Sorting / filtering helpers
    var allPapers: [Paper] { Array(papers.values) }

    /// Whether a paper belongs to the current sidebar scope (all, favorites,
    /// a tag, an author), before the status filter and search apply.
    private func inScope(_ p: Paper) -> Bool {
        switch view {
        case .all, .authors: return true
        case .fav: return p.favorite
        case .tag: return activeTag.map { p.tags.contains($0) } ?? true
        case .author: return activeAuthor.map { p.authors.map(AuthorName.clean).contains($0) } ?? true
        }
    }

    /// Papers in the current scope with the given status (ignores search):
    /// the numbers on the status filter capsules.
    func count(status: String) -> Int {
        let scoped = papers.values.filter(inScope)
        return status == "all" ? scoped.count : scoped.filter { Self.matches($0, status: status) }.count
    }

    var favoritesCount: Int { papers.values.filter(\.favorite).count }

    func filteredPapers() -> [Paper] {
        var out = papers.values.filter(inScope)
        if statusFilter != "all" { out = out.filter { Self.matches($0, status: statusFilter) } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            if q.hasPrefix("#") {
                // "#..." scopes the search to tags only.
                let tag = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
                out = out.filter { !tag.isEmpty && $0.tags.contains { $0.lowercased().contains(tag) } }
            } else {
                out = out.filter {
                    [$0.title ?? "", $0.filename ?? "", $0.tags.joined(separator: " "),
                     $0.authors.joined(separator: " "), $0.doi]
                        .joined(separator: " ").lowercased().contains(q)
                }
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

    /// Status-filter match; "running" also covers queued papers.
    static func matches(_ p: Paper, status: String) -> Bool {
        status == "running" ? p.isActive : p.state == status
    }

    func selectedPaper() -> Paper? { selectedId.flatMap { papers[$0] } }

    // MARK: Sidebar

    /// The sidebar row matching the current scope (a single author keeps
    /// "Authors" highlighted).
    var sidebarSelection: SidebarItem {
        switch view {
        case .all: return .all
        case .fav: return .favorites
        case .authors, .author: return .authors
        case .tag: return activeTag.map { .tag($0) } ?? .all
        }
    }

    /// Point the library at a sidebar row, keeping the inspector on the
    /// selected paper when it's still in scope.
    func selectSidebar(_ item: SidebarItem) {
        guard item != sidebarSelection else { return }
        activeTag = nil; activeAuthor = nil
        switch item {
        case .all: view = .all
        case .favorites: view = .fav
        case .authors: view = .authors
        case .tag(let t): view = .tag; activeTag = t
        }
        if let id = selectedId, !filteredPapers().contains(where: { $0.id == id }) {
            selectedId = nil
        }
    }

    /// The sidebar's rows in order: the library sections, then each tag.
    var sidebarItems: [SidebarItem] {
        [.all, .favorites, .authors] + tagCounts.map { .tag($0.0) }
    }

    /// The count shown beside a sidebar row.
    func sidebarCount(_ item: SidebarItem) -> Int {
        switch item {
        case .all: return papers.count
        case .favorites: return favoritesCount
        case .authors: return authorCounts.count
        case .tag(let tag): return tagCounts.first { $0.0 == tag }?.1 ?? 0
        }
    }

    /// Open a tag's papers (e.g. from a tag chip).
    func showTag(_ tag: String) { selectSidebar(.tag(tag)) }

    // MARK: Library keyboard actions

    /// Space / Return: play or pause the selected paper. False if there's
    /// nothing playable selected, so the key falls through.
    @discardableResult
    func playSelected() -> Bool {
        guard let p = selectedPaper(), p.hasScript || p.hasAudio else { return false }
        togglePlayback(p.id)
        return true
    }

    /// Delete key: ask to delete the selected paper.
    @discardableResult
    func requestDeleteSelected() -> Bool {
        guard let p = selectedPaper() else { return false }
        pendingConfirmation = .delete(p)
        return true
    }

    /// Arrow keys in the grid: move the selection through `visible` papers.
    @discardableResult
    func moveSelection(_ move: LibraryPresentation.Move, in visible: [Paper], columns: Int) -> Bool {
        let current = visible.firstIndex { $0.id == selectedId }
        guard let next = LibraryPresentation.nextIndex(from: current, move: move, columns: columns,
                                                        count: visible.count) else { return false }
        selectedId = visible[next].id
        return true
    }

    /// All papers currently being imported/regenerated (running or queued).
    /// Multiple imports can run concurrently, so the bottom bar can cycle
    /// through them.
    var activeRuns: [Paper] {
        papers.values
            .filter { $0.state == "running" || $0.state == "queued" }
            .sorted { ($0.createdIso ?? "") < ($1.createdIso ?? "") }
    }

    /// The single import the bottom status bar is currently showing.
    var activeRun: Paper? {
        let runs = activeRuns
        guard !runs.isEmpty else { return nil }
        return runs[activeRunIndex % runs.count]
    }

    /// Move the bottom bar's import focus. Cycles across all concurrent imports.
    func focusImport(_ delta: Int) {
        let runs = activeRuns
        guard !runs.isEmpty else { activeRunIndex = 0; return }
        activeRunIndex = (activeRunIndex + delta + runs.count) % runs.count
    }

    var tagCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for p in papers.values {
            for t in Set(p.tags) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
    }

    var authorCounts: [(String, Int)] {
        papersByAuthor.map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedCompare($1.0) == .orderedAscending }
    }

    /// Each author (whitespace-normalised) with their papers, newest first.
    var papersByAuthor: [String: [Paper]] {
        var out: [String: [Paper]] = [:]
        for p in papers.values {
            for a in Set(p.authors.map(AuthorName.clean)) where !a.isEmpty {
                out[a, default: []].append(p)
            }
        }
        return out.mapValues { $0.sorted { ($0.createdIso ?? "") > ($1.createdIso ?? "") } }
    }

    /// Drill the library into one author's papers.
    func showAuthor(_ name: String) {
        view = .author
        activeAuthor = AuthorName.clean(name)
        activeTag = nil
        if let id = selectedId, !filteredPapers().contains(where: { $0.id == id }) { selectedId = nil }
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
            let seen = Set(ids)
            for id in ids {
                if papers[id] == nil, let p: Paper = await storage.exists(Paper.self, K.paper(id)) {
                    papers[id] = p
                }
            }
            for id in Array(papers.keys) where !seen.contains(id) {
                if selectedId == id { selectedId = nil }
                papers.removeValue(forKey: id)
            }
            // Any import left mid-flight by a quit gets picked up again, resuming
            // from its last concluded step (and last synthesized audio turn).
            // A paper still flagged active but already holding a full transcript
            // AND baked audio on disk was finished before a fix persisted its
            // terminal state — self-heal it to done rather than reprocessing.
            for p in papers.values {
                guard p.isActive else { continue }
                let hasScript = await storage.exists(Transcript.self, K.transcript(p.id)) != nil
                let hasBaked = await storage.exists(AudioManifest.self, K.audioManifest(p.id)) != nil
                if hasScript && hasBaked {
                    optimistic(p.id, { $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = "Done" })
                    continue
                }
                Task { await resumePipeline(p.id) }
            }
        }
    }

    // MARK: Metadata mutations
    /// Save a paper's record. Saves run one at a time and each writes the
    /// paper's state *when its turn comes*, so quick successive edits can't
    /// land on disk out of order (an older snapshot overwriting a newer one).
    private var saveQueue: Task<Void, Never>?
    private func persist(_ id: String) {
        let previous = saveQueue
        saveQueue = Task {
            await previous?.value
            guard let latest = papers[id] else { return }
            await storage.save(latest, K.paper(id))
        }
    }

    private func optimistic(_ id: String, _ mutate: (inout Paper) -> Void) {
        guard var p = papers[id] else { return }
        mutate(&p)
        papers[id] = p
        persist(id)
    }
    func toggleFavorite(_ id: String) {
        optimistic(id, { $0.favorite.toggle() })
    }
    func toggleRead(_ id: String, force: Bool? = nil) {
        optimistic(id, { $0.read = force ?? !$0.read })
    }
    func saveTitle(_ id: String, _ title: String) {
        let clean = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { show("Title cannot be empty"); return }
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
        persist(id)
    }
    /// Save the Edit metadata sheet.
    func saveMetadata(_ id: String, _ form: MetadataForm) {
        saveEditableMeta(id, title: form.title, filename: form.filename, authors: form.authorList,
                         affiliations: form.affiliationList, doi: form.doi)
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
        persist(id)
    }

    // MARK: Actions
    /// Convert a paper again. `fresh` discards the stored script and audio so
    /// a new episode is written; otherwise the run resumes from whatever
    /// already landed on disk (used by "Try again" after a failure).
    func rerun(_ id: String, fresh: Bool = true) {
        guard let p = papers[id], !p.isActive else { return }
        let depth = Depth(rawValue: p.depth ?? "") ?? .inDepth
        Task {
            if fresh {
                await discardEpisode(id)
                optimistic(id, { $0.hasScript = false; $0.hasAudio = false; $0.duration = 0 })
            }
            await runPipeline(papers[id], depth: depth)
        }
    }

    /// Drop a paper's script and baked audio, unloading it from the player first.
    private func discardEpisode(_ id: String) async {
        if playingPaperId == id { player.stopAll(); playingPaperId = nil }
        try? await storage.delete(K.script(id))
        try? await storage.delete(K.transcript(id))
        await deleteBakedAudio(id)
    }
    func resetError(_ id: String) {
        guard let p = papers[id] else { return }
        let next = p.dismissingError()
        papers[id] = next
        persist(id)
    }
    func delete(_ id: String) {
        // A running conversion would recreate the folder as it writes.
        guard papers[id]?.isActive != true else {
            show("Wait for the conversion to finish before deleting"); return
        }
        Task {
            do {
                if playingPaperId == id { player.stopAll(); playingPaperId = nil }
                // Let queued saves finish first: one writing into the folder
                // while it's being removed made the delete fail.
                await saveQueue?.value
                try await storage.deleteFolder(K.folder(id))
                thumbCache[id] = nil
                if selectedId == id { selectedId = nil }
                papers.removeValue(forKey: id)
            } catch { show("Delete failed: \(error.localizedDescription)") }
        }
    }

    /// First existing paper (other than `p`) that shares its title or DOI.
    private func findDuplicate(of p: Paper?) -> Paper? {
        guard let p else { return nil }
        func norm(_ s: String?) -> String { (s ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = norm(p.title), doi = norm(p.doi)
        guard !title.isEmpty || !doi.isEmpty else { return nil }
        return papers.values.first { q in
            guard q.id != p.id else { return false }
            let qTitle = norm(q.title), qDoi = norm(q.doi)
            return (!doi.isEmpty && !qDoi.isEmpty && qDoi == doi) ||
                   (!title.isEmpty && !qTitle.isEmpty && qTitle == title)
        }
    }

    /// Pause the import pipeline for the user to allow a duplicate. Resolves
    /// with true to continue the import, false to abort it.
    private func askDuplicate(_ incoming: Paper, duplicateOf dup: Paper) async -> Bool {
        // One prompt at a time: wait for any other import's question to be answered.
        while pendingDuplicate != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        notifier.post(.needsInput("Already in your library?"), paperId: incoming.id, title: incoming.displayTitle)
        return await withCheckedContinuation { c in
            pendingDuplicate = DuplicatePrompt(incoming: incoming, duplicateOf: dup, cont: c)
        }
    }

    /// Called by the confirmation dialog: continues or aborts an in-flight
    /// duplicate import.
    func resolveDuplicate(_ allow: Bool) {
        guard let q = pendingDuplicate else { return }
        notifier.clearInputRequest(paperId: q.incoming.id)
        pendingDuplicate = nil
        q.cont.resume(returning: allow)
    }

    /// Pause the import pipeline to confirm the episode cast the model proposed.
    /// Resolves with nil if the user cancels the import, else the final cast.
    private func askCast(_ id: String, _ proposal: CastProposal, authors: [String], paperTitle: String) async -> [SpeakerConfig]? {
        while pendingCast != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        notifier.post(.needsInput("Choose the voices for your episode"), paperId: id, title: paperTitle)
        return await withCheckedContinuation { c in
            pendingCast = CastPrompt(paperId: id, paperTitle: paperTitle, proposals: proposal.speakers, authors: authors,
                                     authorGenders: proposal.authorGenders, cont: c)
        }
    }

    /// Called by the cast sheet: applies the user's names/voices and resumes the
    /// import pipeline.
    func resolveCast(_ speakers: [SpeakerConfig]) {
        guard let q = pendingCast else { return }
        player.stopPreview()
        notifier.clearInputRequest(paperId: q.paperId)
        pendingCast = nil
        q.cont.resume(returning: speakers)
    }

    /// Called when the cast sheet is cancelled: aborts the in-flight import.
    func cancelCast() {
        guard let q = pendingCast else { return }
        player.stopPreview()
        notifier.clearInputRequest(paperId: q.paperId)
        pendingCast = nil
        q.cont.resume(returning: nil)
    }

    /// Abort an in-flight import and drop its files (used when the user
    /// declines a duplicate).
    private func discardImport(_ id: String) async {
        try? await storage.deleteFolder(K.folder(id))
        if selectedId == id { selectedId = nil }
        papers.removeValue(forKey: id)
    }

    /// Remove a paper's baked per-turn WAVs + manifest (best-effort).
    private func deleteBakedAudio(_ id: String) async {
        if let manifest = await storage.exists(AudioManifest.self, K.audioManifest(id)) {
            for i in manifest.durations.indices {
                try? await storage.delete(K.turn(id, i))
            }
        }
        try? await storage.delete(K.audioManifest(id))
        // Clips are written before the manifest that lists them, so a run that
        // was stopped mid-synthesis leaves unlisted WAVs: sweep the folder.
        if isStandalone, let paperJSON = await storage.url(for: K.paper(id)) {
            let dir = paperJSON.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("turns", isDirectory: true))
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// Wipe everything: library data, all app settings, and caches (Kokoro
    /// model cache + in-memory thumbnail log). Resets the store to a fresh state.
    func clearAll() {
        Task {
            // 1. Library data (deleted best-effort, one paper at a time).
            // The whole papers/ folder, so leftovers of interrupted runs go too.
            if playingPaperId != nil { player.stopAll(); playingPaperId = nil }
            try? await storage.deleteFolder(K.papersRoot)
            papers.removeAll()
            thumbCache.removeAll()
            selectedId = nil
            logEntries = []
            // 2. All settings + old (pre-rename) keys.
            let d = UserDefaults.standard
            for key in ["papertalk.server.json", "papertalk.llm.json", "papertalk.prompts.json", "papertalk.customDepths.json", "papertalk.settingsPage", "papertalk.voiceSpeed", "papertalk.onboarded",
                        "paper2pod.server.json", "paper2pod.llm.json", "paper2pod.onboarded"] {
                d.removeObject(forKey: key)
            }
            // 3. API keys in the Keychain (typed key + env-sourced copies).
            //    Voice models are left alone: they have their own button.
            KeychainStore.delete(LLMSettings.typedKeyAccount)
            KeychainStore.delete(SpeechSettings.typedKeyAccount)
            for env in ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY", llm.keyEnv] where !env.isEmpty {
                KeychainStore.delete(env)
            }
            // 4. Back to a clean reactive state.
            config = ServerConfig.load()   // save() re-persists env defaults
            llm = LLMSettings.load()
            speech = SpeechSettings.load()
            prompts = PromptSettings.defaults
            player.voiceSpeed = PlayerController.defaultSpeed
            customPresets = CustomDepthPresets(entries: [])
            if playingPaperId != nil { player.stopAll(); playingPaperId = nil }
            show("Cleared data, settings and cache")
            // Fresh start: close settings and run first-time setup again.
            showSettings = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            showOnboarding = true
        }
    }
    // MARK: Voice models

    /// Kokoro model folders FluidAudio downloads to `~/.cache/fluidaudio/Models/`
    /// (on Linux, tts.py's `~/.cache/papertalk/kokoro`).
    private var voiceModelDirs: [URL] {
        #if os(Linux)
        let models = KokoroAneResourceDownloader.modelsRoot
        #else
        let models = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
        #endif
        let names = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
        return names.filter { $0.lowercased().hasPrefix("kokoro") }
            .map { models.appendingPathComponent($0, isDirectory: true) }
    }

    /// Bytes used by the downloaded voice models (0 when none).
    func voiceModelsSize() -> Int64 {
        var total: Int64 = 0
        for dir in voiceModelDirs {
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            while let f = files?.nextObject() as? URL {
                total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Delete the downloaded voice models; they're fetched again on next use.
    func clearVoiceModels() {
        guard activeRun == nil else { show("Wait for conversions to finish first"); return }
        player.stopPreview()
        if playingPaperId != nil { player.stopAll(); playingPaperId = nil }
        for dir in voiceModelDirs { try? FileManager.default.removeItem(at: dir) }
        show("Voice models deleted — they'll download again when needed")
    }

    func refreshMeta(_ id: String) {
        Task {
            appendLog("Extracting metadata with LLM…", paper: id)
            guard let pdfData = try? await storage.read(K.pdf(id)) else {
                appendLog("ERROR: no PDF on disk to extract metadata from", paper: id); show("No PDF to read"); return
            }
            let text = LocalPipeline.extractText(pdfData)
            guard !text.isEmpty else { show("Could not read PDF text"); return }
            _ = await extractMetaLLM(id, text: text, fallback: papers[id]?.displayTitle ?? "Untitled")
        }
    }

    /// (Re)extract title/authors/affiliations/DOI/tags via the LLM and merge into
    /// the paper only for fields that are empty, keeping hand-edited values.
    /// Returns the extracted metadata once merged (nil if no LLM or it fails).
    private func extractMetaLLM(_ id: String, text: String, fallback: String) async -> PaperMeta? {
        let base = llm.baseUrl
        guard !base.isEmpty else { show("Configure an LLM to extract metadata"); return nil }
        let p = LocalPipeline(baseUrl: base, apiKey: llm.resolvedKey(), model: llm.model.isEmpty ? "llama3.1:70b" : llm.model)
        var pipeline = p
        pipeline.prompts = prompts
        pipeline.log = { [weak self] line in Task { @MainActor in self?.appendLog(line, paper: id) } }
        do {
            let meta = try await pipeline.extractMeta(text: text, fallbackTitle: fallback)
            optimistic(id, {
                if ($0.title ?? "").isEmpty { $0.title = meta.title }
                if $0.authors.isEmpty { $0.authors = meta.authors }
                if $0.affiliations.isEmpty { $0.affiliations = meta.affiliations }
                if $0.doi.isEmpty { $0.doi = meta.doi }
                if $0.tags.isEmpty { $0.tags = meta.tags }
            })
            appendLog("Metadata: \(meta.authors.joined(separator: ", ")) · \(meta.tags.joined(separator: ", "))", paper: id)
            // Resolve the paper's DOI into a BibTeX citation from doi2bib. Use
            // the currently-stored DOI (authoritative, survives LLM variance)
            // and skip if one is already resolved.
            let doi = (papers[id]?.doi ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !doi.isEmpty {
                if papers[id]?.bibtex == nil {
                    if let bib = await fetchBibliography(doi: doi) {
                        optimistic(id, { $0.bibtex = bib })
                        appendLog("Fetched LaTeX citation from doi2bib", paper: id)
                    } else {
                        appendLog("WARN: could not resolve a citation for \(doi)", paper: id)
                    }
                }
                // Publication date from the DOI service (shown instead of the
                // import date). Leave empty when the DOI doesn't publish one.
                if papers[id]?.publishedIso == nil, let pub = await fetchPublishedDate(doi: doi) {
                    optimistic(id, { $0.publishedIso = pub })
                }
            }
            return meta
        } catch {
            appendLog("WARN: metadata extraction failed: \(error.localizedDescription)", paper: id)
            return nil
        }
    }

    /// Run the in-process pipeline on a PDF (or an existing stored paper).
    func upload(_ pdf: Data, filename: String, depth: Depth, depthNote: String) {
        Task { await runPipeline(nil, pdf: pdf, filename: filename, depth: depth, depthNote: depthNote) }
    }

    // MARK: Audio baking

    /// Render a transcript to per-turn WAVs with the speech backend and store them under
    /// the paper's `turns/` keys. Reports download + per-turn progress across
    /// the given [start, end] band of the unified pipeline bar. Returns nil on
    /// success (hasAudio = true), otherwise a message for the user. Turns already
    /// on disk are reused, so running it again continues where it stopped.
    private func bakeAudio(_ id: String, _ transcript: Transcript, from start: Double, to end: Double) async -> String? {
        let flat = transcript.segments.flatMap { $0.turns }
        guard !flat.isEmpty else { return "The script has nothing to read." }
        let total = flat.count
        func map(_ f: Double) -> Double { start + (end - start) * f }
        if audioGate.isBusy {
            updateRec(id) { $0.stage = "audio"; $0.progress = map(0.0); $0.message = "Waiting for another paper's audio…" }
        }
        await audioGate.acquire()
        defer { audioGate.release() }
        let backend = speechBackend
        let share = backend.preparationShare
        updateRec(id) { $0.stage = "audio"; $0.progress = map(0.0); $0.message = backend.preparingMessage }

        var current = 0
        do {
            // Local Kokoro downloads its model here, on the first part of the band.
            try await backend.prepare { [weak self] fraction, phase in
                Task { @MainActor in
                    self?.updateRec(id) { $0.stage = "audio"; $0.progress = map(fraction * share); $0.message = phase }
                }
            }

            var durations: [Double] = []
            let voiceMap = castVoices(for: id, speakers: flat.map { $0.speaker })
            for (i, turn) in flat.enumerated() {
                current = i
                if Task.isCancelled { return "Stopped." }
                // Resume from the last successfully synthesized chunk: reuse any
                // turn already baked on disk instead of re-synthesizing it.
                let wav: Data
                if let existing = try? await storage.read(K.turn(id, i)) {
                    wav = existing
                } else {
                    let voice = voiceMap[turn.speaker] ?? KokoroSpeech.defaultVoice
                    var parts: [Data] = []
                    for piece in backend.pieces(of: turn.text) {
                        if Task.isCancelled { return "Stopped." }
                        parts.append(try await backend.synthesize(text: piece, voice: voice, speed: Float(player.voiceSpeed)))
                    }
                    wav = KokoroSpeech.joinWAVs(parts)
                    try await storage.write(K.turn(id, i), wav)
                }
                durations.append(KokoroSpeech.wavDuration(wav))
                let frac = share + (1 - share) * Double(i + 1) / Double(total)
                updateRec(id) { $0.stage = "audio"; $0.progress = map(frac); $0.message = "Synthesizing section \(i + 1)/\(total)…" }
            }
            await storage.save(AudioManifest(durations: durations), K.audioManifest(id))
            return nil
        } catch {
            appendLog("Audio synthesis failed at section \(current + 1)/\(total): \(error.localizedDescription)", paper: id)
            return "Voicing stopped at section \(current + 1) of \(total) (\(error.localizedDescription)). "
                + "Try again to continue from there."
        }
    }

    /// The script is fine but voicing failed: keep the script (it can still be
    /// read and played live) and show a resumable error instead of "done".
    private func failAudio(_ id: String, _ message: String) async {
        updateRec(id) {
            $0.state = "error"; $0.stage = "audio"; $0.statusError = message
            $0.hasScript = true; $0.hasAudio = false
        }
        if let p = papers[id] { await storage.save(p, K.paper(id)) }
    }

    /// Preferred voice per speaker for a paper: the paper's configured cast wins
    /// for every speaker it names; anyone else falls back to distinct voices.
    func castVoices(for id: String, speakers: [String]) -> [String: String] {
        let distinct = speakers.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var map: [String: String] = [:]
        var used = Set<String>()
        let configured = papers[id]?.speakers ?? []
        for s in distinct {
            let voice = configured.first { $0.name == s }?.voice
                ?? KokoroSpeech.defaultVoice(forGender: nil, avoiding: used)
            map[s] = voice
            used.insert(voice)
        }
        return map
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
            let vm = castVoices(for: id, speakers: t.segments.flatMap { $0.turns.map(\.speaker) })
            player.prepare(transcript: t, voiceMap: vm)
        }
    }

    /// Play/pause a paper from any control: loads it into the global player
    /// first if needed, and resumes where the listener left off.
    func togglePlayback(_ id: String) {
        if playingPaperId == id, player.turnCount > 0 {
            resumeIfNeeded(id)
            player.playPause()
        } else {
            Task {
                await prepareAudio(for: id)
                resumeIfNeeded(id)
                await player.playWhenReady()
            }
        }
    }

    /// Pick up where the listener left off the first time play is pressed.
    private func resumeIfNeeded(_ id: String) {
        guard let p = papers[id], !player.isPlaying, player.currentTime < 0.5,
              p.progress > 1, p.progress < player.duration - 1 else { return }
        player.seek(toTime: p.progress)
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
        guard let p = papers[id], p.hasScript else { show("No transcript to speak"); return }
        guard !p.isActive else { return }
        notifier.requestPermissionIfNeeded()
        Task {
            guard let t = await transcript(for: id) else { show("No transcript on disk"); return }
            if playingPaperId == id { player.stopAll(); playingPaperId = nil }
            // A complete episode is re-voiced from scratch; an incomplete one
            // (voicing failed part-way) continues from where it stopped.
            if p.hasAudio { await deleteBakedAudio(id) }
            appendLog("Regenerating audio for \(p.displayTitle)…", paper: id)
            let preparing = speechBackend.preparingMessage
            updateRec(id) { $0.state = "running"; $0.stage = "audio"; $0.progress = 0.02; $0.message = preparing }
            if let failure = await bakeAudio(id, t, from: 0.0, to: 1.0) {
                await failAudio(id, failure)
            } else {
                updateRec(id) { $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = "Done"; $0.hasAudio = true }
                if let done = papers[id] { await storage.save(done, K.paper(id)) }
                appendLog("Audio regenerated.", paper: id)
                show("Audio regenerated")
                await prepareAudio(for: id)
            }
        }
    }

    // MARK: Pipeline (always local)
    private func runPipeline(_ existing: Paper?, pdf: Data? = nil, filename: String = "", depth: Depth = .inDepth, depthNote: String = "") async {
        let id = existing?.id ?? UUID().uuidString
        // First conversion is when notifications start to matter: ask then.
        notifier.requestPermissionIfNeeded()
        let name = filename.isEmpty ? (existing?.filename ?? "Paper") : filename

        var rec = existing ?? Paper(id: id, title: "", filename: name, hasPdf: true, hasScript: false, hasAudio: false,
                                     createdIso: ISO8601DateFormatter().string(from: Date()), publishedIso: existing?.publishedIso, state: "queued",
                                     tags: [], favorite: false, authors: [], affiliations: [], doi: "", read: false,
                                     depth: existing?.depth ?? depth.rawValue, bibtex: nil, progress: 0, duration: 0, progressTs: nil,
                                     stage: "extract", message: "Queued", statusError: nil)
        papers[id] = rec
        selectedId = id
        await storage.save(rec, K.paper(id))
        // Store the PDF right away: the record already says hasPdf, and the
        // library shows its cover as soon as the file exists.
        if let pdf {
            try? await storage.write(K.pdf(id), pdf)
            pdfStored(id)
        }
        appendLog("Queued: \(name)", paper: id)

        let base = llm.baseUrl
        let key = llm.resolvedKey()
        let model = llm.model.isEmpty ? "llama3.1:70b" : llm.model

        let pdfData: Data
        if let pdf {
            pdfData = pdf
        } else if let stored = try? await storage.read(K.pdf(id)) {
            pdfData = stored
        } else {
            updateRec(id) { $0.state = "error"; $0.statusError = "No PDF" }; appendLog("ERROR: No PDF to convert", paper: id); return
        }
        var pipeline = LocalPipeline(baseUrl: base, apiKey: key, model: model)
        pipeline.prompts = prompts
        pipeline.log = { [weak self] line in Task { @MainActor in self?.appendLog(line, paper: id) } }
        // Transcript writing spans 0.10 → 0.75 of the unified pipeline bar.
        pipeline.onProgress = { [weak self] frac, label in
            Task { @MainActor in self?.updateRec(id) { $0.progress = 0.10 + 0.65 * frac; $0.message = label } }
        }

        updateRec(id) { $0.state = "running"; $0.stage = "extract"; $0.progress = 0.02; $0.message = "Extracting text…" }
        appendLog("Extracting PDF text…", paper: id)
        let text = LocalPipeline.extractText(pdfData)
        guard !text.isEmpty else {
            updateRec(id) { $0.state = "error"; $0.statusError = "Could not read PDF text" }; appendLog("ERROR: Could not read PDF text", paper: id); return
        }
        appendLog("Extracted \(text.count) characters", paper: id)
        try? await storage.write(K.pdf(id), pdfData)

        // Direct read: skip the LLM entirely. Chunk the extracted text into
        // turns and read it out loud verbatim (no rewriting, just TTS).
        if depth == .direct {
            appendLog("Direct read mode — no LLM processing", paper: id)
            let turns = LocalPipeline.readThroughTurns(text)
            let direct = Transcript(paperTitle: name,
                                    speakers: [Transcript.Speaker(name: "Reader", persona: "")],
                                    segments: [Transcript.Segment(title: "Paper", turns: turns)])
            await storage.save(direct, K.transcript(id))
            updateRec(id) { $0.stage = "audio"; $0.progress = 0.78; $0.message = "Synthesizing audio…" }
            if let failure = await bakeAudio(id, direct, from: 0.80, to: 1.0) {
                await storage.save(direct, K.transcript(id))
                await failAudio(id, failure)
                return
            }
            await finish(id, direct, name, authors: [], pdfData: pdfData, depth: depth, hasAudio: true)
            return
        }

        // Fill title/authors/DOI/tags from the LLM right away (before the script),
        // so the detail view shows real metadata even while the episode is being written.
        if !base.isEmpty {
            _ = await extractMetaLLM(id, text: text, fallback: name)
            // Duplicate-import guard: if an existing paper already has this title
            // or DOI, let the user decide before spending LLM + TTS time on it.
            if existing == nil, let dup = findDuplicate(of: papers[id]),
               !(await askDuplicate(papers[id]!, duplicateOf: dup)) {
                await discardImport(id)
                show("Skipped import — already have “\(dup.displayTitle)”")
                return
            }
            // Cast (who speaks + how they sound): ask the model to propose the
            // voices and names now that metadata and the depth instruction are
            // known, then let the user confirm/rename before writing the script.
            // Resuming with a script already on disk: the names are baked in, so
            // there's nothing to cast.
            let hasScript = await transcript(for: id) != nil
            let proposal = hasScript ? CastProposal(speakers: [], authorGenders: [:]) : await pipeline.proposeCast(title: papers[id]?.displayTitle ?? rec.displayTitle,
                                                               authors: papers[id]?.authors ?? rec.authors,
                                                               cleaned: text, depthNote: depthNote)
            let cast = hasScript ? [] : await askCast(id, proposal, authors: papers[id]?.authors ?? rec.authors,
                                                      paperTitle: papers[id]?.displayTitle ?? rec.displayTitle)
            guard let cast else {
                await discardImport(id)
                show("Import cancelled")
                return
            }
            if !cast.isEmpty {
                // Merge into the live record: `rec` predates the metadata
                // extraction and the progress updates, so it must not overwrite them.
                rec.speakers = cast
                updateRec(id) { $0.speakers = cast }
                if let live = papers[id] { await storage.save(live, K.paper(id)) }
            }
        }

        guard !base.isEmpty else {
            // no LLM configured: fall back to a read-through transcript
            appendLog("No LLM URL configured — using read-through transcript", paper: id)
            let fallback = Transcript(paperTitle: name, speakers: [Transcript.Speaker(name: "Reader", persona: "")],
                                      segments: [Transcript.Segment(title: "Paper", turns: text.prefix(8000).split(separator: "\n")
                                          .map { String($0) }.filter { !$0.isEmpty }.map { Transcript.Turn(speaker: "Reader", text: $0) })] )
            await finish(id, fallback, name, authors: [], pdfData: pdfData, hasAudio: false)
            return
        }

        updateRec(id) { $0.state = "running"; $0.stage = "segments"; $0.progress = 0.08; $0.message = "Planning episode…" }
        appendLog("Calling \(model) @ \(base)…", paper: id)
        do {
            // Resume: if a transcript already landed on disk before a quit, skip
            // the LLM call and pick up directly at audio synthesis.
            let script: Transcript
            if let persisted = await transcript(for: id), !persisted.segments.isEmpty {
                script = persisted
                appendLog("Resuming with previously generated transcript…", paper: id)
            } else {
                let result = try await pipeline.generateTranscript(text: text, depth: depth, depthNote: depthNote,
                                                                    host: rec.speakers.first?.name,
                                                                    expert: rec.speakers.count > 1 ? rec.speakers[1].name : nil)
                script = result.transcript
                // Persist now so an interrupted run can resume past segments later.
                await storage.save(script, K.transcript(id))
                appendLog("Got transcript (\(script.segments.count) segments)", paper: id)
            }
            updateRec(id) { $0.stage = "audio"; $0.progress = 0.78; $0.message = "Synthesizing audio…" }
            if let failure = await bakeAudio(id, script, from: 0.80, to: 1.0) {
                await failAudio(id, failure)
                return
            }
            await finish(id, script, papers[id]?.displayTitle ?? name,
                         authors: papers[id]?.authors ?? [], pdfData: pdfData, depth: depth, hasAudio: true)
        } catch {
            updateRec(id) { $0.state = "error"; $0.statusError = error.localizedDescription }
            appendLog("ERROR: \(error.localizedDescription)", paper: id)
            show("Conversion failed: \(error.localizedDescription)")
        }
    }

    private func resumePipeline(_ id: String) async {
        guard let existing = papers[id] else { return }
        let depth = Depth(rawValue: existing.depth ?? "") ?? .inDepth
        appendLog("Resuming import of \(existing.displayTitle)…", paper: id)
        await runPipeline(existing, depth: depth)
    }

    private func finish(_ id: String, _ t: Transcript, _ title: String, authors: [String], pdfData: Data?, depth: Depth = .inDepth, hasAudio: Bool) async {
        await storage.save(t, K.transcript(id))
        if let pdfData, !pdfData.isEmpty { try? await storage.write(K.pdf(id), pdfData) }
        updateRec(id) {
            $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = "Done"
            $0.hasScript = true; $0.hasAudio = hasAudio
            $0.title = $0.title ?? title
            $0.authors = authors.isEmpty ? $0.authors : authors
            $0.depth = depth.rawValue
        }
        if let done = papers[id] { await storage.save(done, K.paper(id)) }
        appendLog("Done: \(title)", paper: id)
        show("Converted")
    }

    private func updateRec(_ id: String, _ mutate: (inout Paper) -> Void) {
        guard var p = papers[id] else { return }
        let wasActive = p.isActive
        mutate(&p)
        papers[id] = p
        // A run just ended: tell the user if they're in another app.
        if wasActive && p.isDone {
            notifier.post(.ready, paperId: id, title: p.displayTitle)
        } else if wasActive && p.isError {
            notifier.post(.failed(p.statusError ?? "Something went wrong"), paperId: id, title: p.displayTitle)
        }
    }

    /// Bring a paper into view and select it (e.g. from a notification).
    func reveal(_ id: String) {
        guard papers[id] != nil else { return }
        if !filteredPapers().contains(where: { $0.id == id }) {
            view = .all; activeTag = nil; activeAuthor = nil
            statusFilter = "all"; search = ""
        }
        selectedId = id
    }

    /// Ask doi2bib to turn a DOI into a BibTeX citation. Returns nil on any
    /// failure, so citation resolution never blocks or fails an import.
    private func fetchBibliography(doi: String) async -> String? {
        var doi = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doi.isEmpty else { return nil }
        if doi.hasPrefix("doi:") { doi = String(doi.dropFirst(4)) }
        if let range = doi.range(of: "doi.org/") { doi = String(doi[range.upperBound...]) }
        var req = URLRequest(url: URL(string: "https://www.doi2bib.org/8350e5a3e24c153df2275c9f80692773/doi2bib?id=" + doi)!)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("@") ? s : nil
    }

    /// Best-effort publication date (YYYY, YYYY-MM or YYYY-MM-DD) for a DOI,
    /// from Crossref. Returns nil when the registry has no date.
    private func fetchPublishedDate(doi: String) async -> String? {
        var doi = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doi.isEmpty else { return nil }
        if doi.hasPrefix("doi:") { doi = String(doi.dropFirst(4)) }
        if let range = doi.range(of: "doi.org/") { doi = String(doi[range.upperBound...]) }
        guard let url = URL(string: "https://api.crossref.org/works/" + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return nil }
        let parts = (message["published"] as? [String: Any])?["date-parts"] as? [[Int]]
            ?? (message["issued"] as? [String: Any])?["date-parts"] as? [[Int]]
        guard let p = parts?.first, p.first ?? 0 > 0 else { return nil }
        var s = String(p[0])
        if p.count > 1, p[1] > 0 {
            s += String(format: "-%02d", p[1])
            if p.count > 2, p[2] > 0 { s += String(format: "-%02d", p[2]) }
        }
        return s
    }

    // MARK: Updates

    /// This copy's version and commit; tests replace it.
    var build = AppBuild.current
    @Published private(set) var isCheckingForUpdates = false
    /// Result of the last update check, shown as an alert.
    @Published var updateAlert: UpdateAlert?

    /// Menu entry point: check GitHub for a newer release on `channel`.
    func requestUpdateCheck(_ channel: ReleaseChannel) {
        Task { await checkForUpdates(channel) }
    }

    func checkForUpdates(_ channel: ReleaseChannel, checker: UpdateChecker = UpdateChecker()) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        let outcome: UpdateCheck.Outcome
        do {
            let newest = UpdateCheck.newest(in: try await checker.releases(), channel: channel)
            var ahead: Bool?
            if let pair = UpdateCheck.commitsToCompare(build: build, newest: newest, channel: channel) {
                ahead = await checker.isAhead(base: pair.base, head: pair.head)
            }
            outcome = UpdateCheck.outcome(build: build, newest: newest, channel: channel, devIsAhead: ahead)
        } catch {
            outcome = .failed(error.message)
        }
        updateAlert = UpdateAlert(outcome, channel: channel, build: build)
    }

    func openUpdateLink(_ alert: UpdateAlert) {
        updateAlert = nil
        if let link = alert.link { NSWorkspace.shared.open(link) }
    }

    func show(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func saveCustomPreset(name: String, text: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanText.isEmpty else { return }
        var entries = customPresets.entries.filter { $0.name != cleanName }
        entries.append(.init(name: cleanName, text: cleanText))
        customPresets = CustomDepthPresets(entries: entries)
        customPresets.save()
        show("Saved prompt “\(cleanName)”")
    }

    func select(_ id: String?) { selectedId = id }
}

enum SortOption: String, CaseIterable, Identifiable {
    case newest, oldest, title = "Title", recent = "Recently converted"
    var id: String { rawValue }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid = "Grid", list = "List"
    var id: String { rawValue }
}