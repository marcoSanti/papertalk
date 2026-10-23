// The app's single source of truth: every piece of state the views show, every action they
// can take, and the import pipeline that ties the LLM, the speech backend and storage together
// (extract text → metadata → duplicate check → cast → script → mind map → audio).
// Both the macOS and the Linux interfaces drive this same store.

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

/// All app state and mutations, on the main actor. Views read its `@Published` properties and
/// call its methods; long work (conversions, mind maps) runs in tasks it tracks.
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
    /// The library is on this machine (no storage server), so Finder can show its files.
    var isStandalone: Bool {
        if let storageOverride { return storageOverride is LocalStorage }
        return config.apiBase.isEmpty
    }

    /// Reveal the paper's folder in Finder (local storage only).
    func revealInFinder(_ id: String) {
        guard isStandalone else { return }
        Task {
            if let u = await storage.url(for: K.folder(id)) {
                NSWorkspace.shared.activateFileViewerSelecting([u])
            }
        }
    }

    /// Every paper in the library, by id. Records are saved through `persist`.
    @Published var papers: [String: Paper] = [:] { didSet { authorIndex = nil } }
    /// The paper shown in the details panel.
    @Published var selectedId: String?
    /// Global audio player shown in the bottom status bar (iTunes-style).
    @Published var player: PlayerController
    /// The paper whose audio the global player currently holds.
    @Published var playingPaperId: String?
    /// Which of the active imports the bottom bar is focused on.
    @Published var activeRunIndex = 0
    /// Paper currently open in the metadata edit sheet.
    @Published var editingPaper: Paper?
    /// The transcript sheet opened from a context menu.
    @Published var transcriptSheet: TranscriptSheet?
    /// A transcript sheet's content, loaded before it opens so it never shows the empty branch first.
    struct TranscriptSheet: Identifiable {
        let id = UUID()
        let title: String
        let transcript: Transcript?
    }
    /// Open the transcript sheet with the script as it is on disk now (a rerun may have replaced it).
    func showTranscript(_ id: String) {
        Task { if let sheet = await transcriptSheet(for: id) { transcriptSheet = sheet } }
    }
    /// A transcript sheet for `id`, read from disk now; nil when the paper is gone.
    func transcriptSheet(for id: String) async -> TranscriptSheet? {
        guard let p = papers[id] else { return nil }
        return TranscriptSheet(title: p.displayTitle, transcript: await transcript(for: id))
    }
    /// The paper the player holds.
    var playingPaper: Paper? { playingPaperId.flatMap { papers[$0] } }
    /// Whether the player holds `id`'s episode (playing or paused).
    func isLoaded(_ id: String) -> Bool { playingPaperId == id }
    /// Whether `id`'s episode is playing now.
    func isPlaying(_ id: String) -> Bool { isLoaded(id) && player.isPlaying }
    /// Whether `id`'s mind map is being drawn.
    func isDrawingMindMap(_ id: String) -> Bool { mindMapJobs[id] != nil }
    /// Whether the import sheet is open, and a file to pre-load into it
    /// (set when a PDF is dropped on the library).
    @Published var showUpload = false
    /// A PDF dropped on the library, loaded into the import sheet when it opens.
    @Published var pendingUploadURL: URL?
    /// Open the import sheet, optionally with a dropped PDF already in it.
    func beginImport(_ url: URL? = nil) {
        rerunning = nil
        pendingUploadURL = url
        showUpload = true
    }
    /// A paper the import sheet is open to convert again (nil: a new import).
    @Published var rerunning: Paper?
    /// Open the import sheet for `p`, to choose its depth (and length, language) again.
    func beginRerun(_ p: Paper) {
        rerunning = p
        pendingUploadURL = nil
        showUpload = true
    }
    /// Fill a just-opened import sheet: the shown library, the paper being rerun. Returns the
    /// dropped PDF to load into it, once.
    func prepareImport(_ form: inout ImportForm) -> URL? {
        form.library = shownLibrary
        if let p = rerunning { form.rerun(p) }
        defer { pendingUploadURL = nil }
        return pendingUploadURL
    }
    /// The import sheet's Start: rerun the paper it was opened for, or import its PDF.
    /// False (the sheet stays open) while the form is incomplete.
    @discardableResult
    func startImport(_ form: ImportForm) -> Bool {
        guard form.canStart else { return false }
        if let p = form.rerunning {
            rerun(p.id, depth: form.depth, depthNote: form.depthNote,
                  targetMinutes: form.targetMinutes, scriptLanguage: form.scriptLanguage)
        } else if let s = form.submission {
            upload(s.data, filename: s.filename, depth: s.depth, depthNote: s.depthNote,
                   targetMinutes: s.targetMinutes, scriptLanguage: s.scriptLanguage, library: s.library)
        } else {
            return false
        }
        return true
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
    /// An env-sourced key is copied to the Keychain for apps launched from Finder.
    func saveSpeechSettings(_ next: SpeechSettings) {
        guard next != speech else { return }
        next.saveResolvedKey()
        speech = next
    }

    /// Save the edited LLM prompts (only when they changed).
    func savePrompts(_ next: PromptSettings) {
        if next != prompts { prompts = next }
    }

    /// The interface language. Published so every view redraws in the new one;
    /// episodes keep the language they were written in.
    @Published private(set) var language = Localization.language

    /// Switch the interface language and remember it.
    func setLanguage(_ next: AppLanguage) {
        guard next != language else { return }
        Localization.language = next
        UserDefaults.standard.set(next.rawValue, forKey: Localization.defaultsKey)
        language = next
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
            failures.append(L("storage"))
        }
        if !llmBaseURL.isEmpty,
           (try? await LocalPipeline(baseUrl: llmBaseURL, apiKey: apiKey, model: model).listModels()) == nil {
            failures.append("LLM")
        }
        return failures.isEmpty
            ? (true, L("Both connections look good."))
            : (false, L("Could not reach: {0}.", failures.joined(separator: ", ")))
    }

    /// Setup wizard: save everything and close it.
    func finishSetup(server: ServerConfig, llm next: LLMSettings, speech voices: SpeechSettings) {
        config = server
        llm = next
        llm.saveResolvedKey()
        saveSpeechSettings(voices)
        show(L("Setup complete"))
        markOnboarded()
    }

    /// Rerun from a menu or button: confirm first when it would replace an episode, then ask
    /// for the depth in the import sheet.
    func requestRerun(_ p: Paper) {
        if PaperPresentation.rerunNeedsConfirmation(p) { pendingConfirmation = .rerun(p) } else { beginRerun(p) }
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
        case .rerun(let p): beginRerun(p)
        case .deleteAudio(let p), .finishedListening(let p): deleteAudio(p.id)
        case .redrawAllMindMaps: redrawAllMindMaps()
        case .deleteLibrary(let library): deleteLibrary(library.id)
        }
    }

    /// The dialog's third button, where it has one (`ConfirmationText.secondaryLabel`).
    func confirmSecondary(_ pending: PendingConfirmation) {
        pendingConfirmation = nil
        if case .finishedListening = pending { askToDeleteListenedAudio = false }
    }

    /// A destructive action waiting for the user's yes (see `ConfirmationText` for the wording).
    enum PendingConfirmation: Identifiable {
        case delete(Paper), rerun(Paper), deleteAudio(Paper)
        /// An episode was listened to the end: keep its audio or free the space?
        case finishedListening(Paper)
        /// Redraw the mind maps of this many papers (`mindMapsToRedraw`), replacing them.
        case redrawAllMindMaps(Int)
        /// Delete a library; its papers stay, in no library.
        case deleteLibrary(Library)
        var id: String {
            switch self {
            case .delete(let p): return "delete-\(p.id)"
            case .rerun(let p): return "rerun-\(p.id)"
            case .deleteAudio(let p): return "deleteAudio-\(p.id)"
            case .finishedListening(let p): return "finished-\(p.id)"
            case .redrawAllMindMaps: return "redrawAllMindMaps"
            case .deleteLibrary(let library): return "deleteLibrary-\(library.id)"
            }
        }
    }

    /// Whether finishing an episode asks to delete its audio.
    @Published var askToDeleteListenedAudio = UserDefaults.standard.object(forKey: AppStore.askDeleteKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(askToDeleteListenedAudio, forKey: Self.askDeleteKey) }
    }
    /// User-defaults key of `askToDeleteListenedAudio`.
    nonisolated static let askDeleteKey = "papertalk.askDeleteListenedAudio"

    /// Delete a paper's voiced audio, keeping its script: it can still be read,
    /// played with live voices, or voiced again with Regenerate audio.
    func deleteAudio(_ id: String) {
        guard let p = papers[id], PaperPresentation.canDeleteAudio(p) else { return }
        Task {
            if playingPaperId == id { player.stopAll(); playingPaperId = nil }
            await deleteBakedAudio(id)
            optimistic(id, { $0.hasAudio = false })
            appendLog("Deleted the audio.", paper: id)
            show(L("Audio deleted"))
        }
    }

    /// An episode played to its end: offer to delete its audio.
    func episodeFinished(_ id: String) {
        guard askToDeleteListenedAudio, pendingConfirmation == nil,
              let p = papers[id], PaperPresentation.canDeleteAudio(p) else { return }
        pendingConfirmation = .finishedListening(p)
    }
    /// Pending "already in library" prompt whose answer is awaited by the
    /// import pipeline. Lives on the store so it survives sheet dismissal.
    struct DuplicatePrompt {
        let incoming: Paper
        let duplicateOf: Paper
        let cont: CheckedContinuation<Bool, Never>
    }
    /// The duplicate question on screen, if any; imports queue for it one at a time.
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
        let cont: CheckedContinuation<CastChoice?, Never>
    }
    /// The cast sheet's answer: who speaks, and whether to voice the script now.
    struct CastChoice {
        let speakers: [SpeakerConfig]
        let voiceAudio: Bool
    }
    /// The cast question on screen, if any; imports queue for it one at a time.
    @Published var pendingCast: CastPrompt?
    /// System notifications while the app is in the background.
    let notifier = Notifier()
    /// Papers are voiced one at a time: concurrent bakes ran small Macs out of memory.
    let audioGate = SerialGate()
    /// Imports read their PDF and write their script one at a time, in arrival order; several at
    /// once crashed the app. A paper leaves it for `audioGate`, so the next script overlaps its voicing.
    let importGate = SerialGate()

    // filtering
    @Published var view: ViewMode = .all
    @Published var activeTag: String?
    @Published var activeAuthor: String?
    @Published var activeLibrary: String?
    /// Named custom-depth prompts, selectable from the upload sheet's dropdown.
    @Published var customPresets: CustomDepthPresets = .load()
    /// Library presentation: thumbnail grid or compact list.
    @Published var libraryLayout: LibraryLayout = .grid
    @Published var search = ""
    @Published var sort: SortOption = .newest
    @Published var statusFilter: String = "all"
    /// Show every status again (the filtered-out empty state's button).
    func clearStatusFilter() { statusFilter = "all" }

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
    /// Add a timestamped line to the activity log (kept in English, for bug reports).
    func appendLog(_ line: String, paper id: String? = nil) {
        logEntries.append(LogEntry(paperId: id, text: "[\(Self.logFmt.string(from: Date()))] \(line)"))
        if logEntries.count > 2000 { logEntries.removeFirst(logEntries.count - 2000) }
    }
    /// One paper's lines, for its activity pane.
    func logLines(for id: String) -> [String] {
        logEntries.filter { $0.paperId == id }.map(\.text)
    }

    /// Raw values are remembered between launches: add new pages at the end.
    enum SettingsPage: Int, Identifiable {
        case llm, server, prompts, presets, clear, voices, general
        var id: Int { rawValue }
    }
    /// Whether the unified settings sheet is open.
    @Published var showSettings = false
    /// The settings page to show once open.
    @Published var settingsPage: SettingsPage = .llm
    /// Open the settings sheet on `page`.
    func openSettings(_ page: SettingsPage) {
        settingsPage = page
        showSettings = true
    }

    private var toastTask: Task<Void, Never>?
    private var playbackCancelables: Set<AnyCancellable> = []

    /// What the library shows: everything, favourites, the Authors screen, one tag, one author or one library.
    enum ViewMode { case all, fav, authors, tag, author, library }

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

    /// The app's store, in the saved (or the system's) interface language.
    /// Tests build `AppStore` directly and stay in English.
    static func launch() -> AppStore {
        Localization.language = Localization.load()
        return AppStore()
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
    /// Remember that setup ran, and close it.
    func markOnboarded() {
        UserDefaults.standard.set(true, forKey: "papertalk.onboarded")
        showOnboarding = false
    }

    /// The cover `loadThumbnail` already rendered, if any (no loading).
    func cachedThumbnail(_ id: String) -> NSImage? { thumbCache[id] }

    /// Renders the first page of a stored PDF as a cached thumbnail, or nil when
    /// the PDF is missing/unreadable (caller falls back to a placeholder).
    func loadThumbnail(_ id: String) async -> NSImage? {
        if let cached = thumbCache[id] { return cached }
        // Rendered off the main thread: a big library drawing its covers froze scrolling.
        guard let data = try? await storage.read(K.pdf(id)),
              let image = await Task.detached(operation: { Self.thumbnail(of: data) }).value else { return nil }
        thumbCache[id] = image
        return image
    }

    nonisolated private static func thumbnail(of data: Data, width: CGFloat = 280) -> NSImage? {
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
        case .library: return p.library == activeLibrary
        }
    }

    /// Papers in the current scope with the given status (ignores search):
    /// the numbers on the status filter capsules.
    func count(status: String) -> Int {
        let scoped = papers.values.filter(inScope)
        return status == "all" ? scoped.count : scoped.filter { Self.matches($0, status: status) }.count
    }

    /// The Favorites row's count.
    var favoritesCount: Int { papers.values.filter(\.favorite).count }

    /// The papers the library shows: the sidebar scope, then the status filter and the search
    /// ("#…" searches tags only), sorted by the chosen order.
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

    /// The selected paper's current record.
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
        case .library: return activeLibrary.map { .library($0) } ?? .all
        }
    }

    /// Point the library at a sidebar row, keeping the inspector on the
    /// selected paper when it's still in scope.
    func selectSidebar(_ item: SidebarItem) {
        guard item != sidebarSelection else { return }
        activeTag = nil; activeAuthor = nil; activeLibrary = nil
        switch item {
        case .all: view = .all
        case .favorites: view = .fav
        case .authors: view = .authors
        case .tag(let t): view = .tag; activeTag = t
        case .library(let id): view = .library; activeLibrary = id
        }
        if let id = selectedId, !filteredPapers().contains(where: { $0.id == id }) {
            selectedId = nil
        }
    }

    /// The sidebar's rows in order: the library sections, each library, then each tag.
    var sidebarItems: [SidebarItem] {
        [.all, .favorites, .authors] + libraries.map { .library($0.id) } + tagCounts.map { .tag($0.0) }
    }

    /// The count shown beside a sidebar row.
    func sidebarCount(_ item: SidebarItem) -> Int {
        switch item {
        case .all: return papers.count
        case .favorites: return favoritesCount
        case .authors: return authorCounts.count
        case .tag(let tag): return tagCounts.first { $0.0 == tag }?.1 ?? 0
        case .library(let id): return papers.values.filter { $0.library == id }.count
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

    /// The first conversion running, if any (they share the speech engine).
    var activeRun: Paper? { activeRuns.first }

    /// What the bottom bar's progress pane cycles through: conversions, then
    /// mind maps being drawn (shown as a running copy of their paper).
    var progressItems: [Paper] {
        let runs = activeRuns
        let maps = mindMapJobs.keys.sorted().compactMap { id -> Paper? in
            guard var p = papers[id], let job = mindMapJobs[id], !runs.contains(where: { $0.id == id }) else { return nil }
            p.state = "running"; p.stage = Paper.mindMapStage
            p.progress = job.progress; p.message = job.message; p.statusError = nil
            return p
        }
        return runs + maps
    }

    /// The progress item the bottom bar is currently showing.
    var shownProgress: Paper? {
        let items = progressItems
        guard !items.isEmpty else { return nil }
        return items[activeRunIndex % items.count]
    }

    /// Move the bottom bar's progress focus. Cycles across everything in progress.
    func focusImport(_ delta: Int) {
        let runs = progressItems
        guard !runs.isEmpty else { activeRunIndex = 0; return }
        activeRunIndex = (activeRunIndex + delta + runs.count) % runs.count
    }

    /// Every tag with how many papers have it, most papers first, ties A–Z.
    var tagCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for p in papers.values {
            for t in Set(p.tags) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value
            : $0.key.localizedCompare($1.key) == .orderedAscending }
    }

    /// Every author with how many papers they're on, A–Z.
    var authorCounts: [(String, Int)] {
        papersByAuthor.map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedCompare($1.0) == .orderedAscending }
    }

    /// Each author (whitespace-normalised) with their papers, newest first.
    var papersByAuthor: [String: [Paper]] {
        // Views ask for it once per author row on every redraw: build it once per library change.
        if let cached = authorIndex { return cached }
        var out: [String: [Paper]] = [:]
        for p in papers.values {
            for a in Set(p.authors.map(AuthorName.clean)) where !a.isEmpty {
                out[a, default: []].append(p)
            }
        }
        let index = out.mapValues { $0.sorted { ($0.createdIso ?? "") > ($1.createdIso ?? "") } }
        authorIndex = index
        return index
    }
    /// `papersByAuthor` as last built; cleared whenever `papers` changes.
    private var authorIndex: [String: [Paper]]?

    /// How many library papers `name` (as an author line spells it) is on; at least this one.
    func paperCount(byAuthor name: String) -> Int {
        papersByAuthor[AuthorName.clean(name)]?.count ?? 1
    }

    /// The author drilled into, while the library shows one author's papers.
    var shownAuthor: String? { view == .author ? activeAuthor : nil }
    /// True on the Authors index (every author), not one author's papers.
    var showsAuthorIndex: Bool { view == .authors && activeAuthor == nil }

    /// Back from one author's papers to every author.
    func showAllAuthors() {
        view = .authors
        activeAuthor = nil
    }

    /// Drill the library into one author's papers.
    func showAuthor(_ name: String) {
        view = .author
        activeAuthor = AuthorName.clean(name)
        activeTag = nil; activeLibrary = nil
        if let id = selectedId, !filteredPapers().contains(where: { $0.id == id }) { selectedId = nil }
    }

    // MARK: Artifact access (all via the active storage)
    func transcript(for id: String) async -> Transcript? {
        await storage.exists(Transcript.self, K.transcript(id))
    }

    /// A paper's saved mind map, nil when there's none or it can't be read. Connections to papers
    /// no longer in the library are left out.
    func mindMap(for id: String) async -> MindMap? {
        guard var map = await storage.exists(MindMap.self, K.mindMap(id)) else { return nil }
        if map.external != nil { map.external = map.externalLinks.filter { papers[$0.paperId] != nil } }
        return map
    }

    /// The library's papers and how their saved mind maps connect them (and, when the library
    /// connects across, the papers elsewhere they connect to).
    func libraryMap(_ libraryId: String) async -> LibraryMap {
        let members = papers.values.filter { $0.library == libraryId }
        var maps: [String: MindMap] = [:]
        for p in members where p.hasMindMap == true {
            if let m = await mindMap(for: p.id) { maps[p.id] = m }
        }
        // Papers elsewhere join the map only if this library connects across.
        let across = libraries.first { $0.id == libraryId }?.connectsAcross == true
        return LibraryMap(papers: members, maps: maps,
                          outside: across ? papers.values.filter { $0.library != libraryId } : [])
    }

    /// Bumped whenever a paper's saved mind map changes, so an open map window can reload it.
    @Published private(set) var mindMapRevision: [String: Int] = [:]

    /// Save a mind map (edited in its window, or with new connections) and keep its connections
    /// two-way: every paper it links to, linked to before, or in `involving` gets the same
    /// connections back, written onto a fresh read of its map. A connection whose other concept
    /// is gone (or whose paper left the library) is dropped. Queued behind earlier saves, so quick
    /// edits land in order.
    func saveMindMap(_ id: String, _ map: MindMap, involving extra: Set<String> = []) {
        guard papers[id] != nil else { return }
        let previous = saveQueue
        saveQueue = Task {
            await previous?.value
            let old = await storage.exists(MindMap.self, K.mindMap(id))
            let involved = extra.union((old?.externalLinks ?? []).map(\.paperId)).union(map.externalLinks.map(\.paperId))
            var others: [String: MindMap] = [:]
            for pid in involved where pid != id && papers[pid] != nil {
                if let m = await storage.exists(MindMap.self, K.mindMap(pid)) { others[pid] = m }
            }
            var mine = map
            mine.external = map.external?.filter { others[$0.paperId]?.node($0.nodeId) != nil }
            await storage.save(mine, K.mindMap(id))
            var changed = [id]
            for (pid, m) in MindMapConnections.mirrored(mine.externalLinks, of: id, title: papers[id]?.displayTitle ?? "",
                                                        map: mine, into: others) {
                await storage.save(m, K.mindMap(pid))
                changed.append(pid)
            }
            for c in changed { mindMapRevision[c, default: 0] += 1 }
        }
    }

    // MARK: Library
    func refresh() {
        Task {
            let ids = (try? await storage.list()) ?? []
            libraries = await storage.exists([Library].self, K.libraries) ?? []
            let seen = Set(ids)
            // One change for the whole scan: a redraw per paper made opening a big library crawl.
            var loaded: [String: Paper] = [:]
            for id in ids where papers[id] == nil {
                if let p: Paper = await storage.exists(Paper.self, K.paper(id)) { loaded[id] = p }
            }
            papers.merge(loaded) { current, _ in current }
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
                    optimistic(p.id, { $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = L("Done") })
                    continue
                }
                startRun(p.id) { await self.resumePipeline(p.id) }
            }
        }
    }

    // MARK: Metadata mutations
    /// Save a paper's record. Saves run one at a time and each writes the
    /// paper's state *when its turn comes*, so quick successive edits can't
    /// land on disk out of order (an older snapshot overwriting a newer one).
    private var saveQueue: Task<Void, Never>?
    /// Queue a save of the paper's record (see `saveQueue`).
    private func persist(_ id: String) {
        let previous = saveQueue
        saveQueue = Task {
            await previous?.value
            guard let latest = papers[id] else { return }
            await storage.save(latest, K.paper(id))
        }
    }

    /// Change a paper in memory now, and save it.
    private func optimistic(_ id: String, _ mutate: (inout Paper) -> Void) {
        guard var p = papers[id] else { return }
        mutate(&p)
        papers[id] = p
        persist(id)
    }
    /// Star or unstar a paper.
    func toggleFavorite(_ id: String) {
        optimistic(id, { $0.favorite.toggle() })
    }
    /// Mark a paper listened or not; `force` sets it instead of toggling.
    func toggleRead(_ id: String, force: Bool? = nil) {
        optimistic(id, { $0.read = force ?? !$0.read })
    }
    /// Rename a paper (whitespace tidied); an empty title is refused with a toast.
    func saveTitle(_ id: String, _ title: String) {
        let clean = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { show(L("Title cannot be empty")); return }
        guard clean != (papers[id]?.title ?? "") else { return }
        optimistic(id, { $0.title = clean })
    }
    /// Add a tag; spaces become underscores, and an existing tag is ignored.
    func addTag(_ id: String, _ tag: String) {
        let clean = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
        guard !clean.isEmpty, let p = papers[id], !p.tags.contains(clean) else { return }
        optimistic(id, { $0.tags = $0.tags + [clean] })
    }
    /// Remove a tag from a paper.
    func removeTag(_ id: String, _ tag: String) {
        guard let p = papers[id] else { return }
        let next = p.tags.filter { $0 != tag }
        guard next.count != p.tags.count else { return }
        optimistic(id, { $0.tags = next })
    }
    // MARK: Libraries

    /// The user's libraries, in the order made (`libraries.json`).
    @Published private(set) var libraries: [Library] = []
    /// The New/Edit Library sheet, when open.
    @Published var editingLibrary: LibraryForm?

    /// The library the sidebar shows, where new imports are filed; nil elsewhere.
    var shownLibrary: String? { view == .library ? activeLibrary : nil }
    /// The library title for the current scope.
    var activeLibraryName: String? { libraries.first { $0.id == activeLibrary }?.name }

    /// Queue a save of `libraries.json` (behind paper saves, like `persist`).
    private func persistLibraries() {
        let previous = saveQueue
        saveQueue = Task {
            await previous?.value
            await storage.save(libraries, K.libraries)
        }
    }

    /// Save the library sheet: add the library, or update it in place.
    func saveLibrary(_ form: LibraryForm) {
        guard form.canSave else { return }
        if let i = libraries.firstIndex(where: { $0.id == form.id }) {
            libraries[i] = form.library
        } else {
            libraries.append(form.library)
        }
        persistLibraries()
    }

    /// Ask before deleting a library.
    func requestDeleteLibrary(_ id: String) {
        if let library = libraries.first(where: { $0.id == id }) { pendingConfirmation = .deleteLibrary(library) }
    }

    /// Delete a library. Its papers stay in All Papers, in no library.
    func deleteLibrary(_ id: String) {
        guard libraries.contains(where: { $0.id == id }) else { return }
        if activeLibrary == id { selectSidebar(.all) }
        libraries.removeAll { $0.id == id }
        persistLibraries()
        for p in papers.values where p.library == id { optimistic(p.id, { $0.library = nil }) }
    }

    /// File a paper in a library (nil: in none).
    func moveToLibrary(_ id: String, _ library: String?) {
        guard let p = papers[id], p.library != library else { return }
        optimistic(id, { $0.library = library })
    }

    /// Remember where the listener is (seconds) and the episode's length.
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

    /// Save edited metadata: fields trimmed, empty list entries dropped.
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
    /// A `depth` (from the rerun sheet) replaces the paper's depth, length and language.
    func rerun(_ id: String, fresh: Bool = true, depth chosen: Depth? = nil, depthNote: String = "",
               targetMinutes: Int? = nil, scriptLanguage: AppLanguage = .english) {
        guard let p = papers[id], !p.isActive else { return }
        let depth = chosen ?? Depth(rawValue: p.depth ?? "") ?? .inDepth
        startRun(id) {
            if fresh {
                await self.discardEpisode(id)
                self.optimistic(id, {
                    $0.hasScript = false; $0.hasAudio = false; $0.duration = 0
                    if chosen != nil {
                        $0.depth = depth.rawValue
                        $0.targetMinutes = targetMinutes
                        $0.scriptLanguage = scriptLanguage == .english ? nil : scriptLanguage.rawValue
                    }
                })
            }
            await self.runPipeline(self.papers[id], depth: depth, depthNote: depthNote)
        }
    }

    /// Drop a paper's script and baked audio, unloading it from the player first.
    private func discardEpisode(_ id: String) async {
        if playingPaperId == id { player.stopAll(); playingPaperId = nil }
        try? await storage.delete(K.script(id))
        try? await storage.delete(K.transcript(id))
        await deleteBakedAudio(id)
    }
    /// Dismiss a failure: back to done if an episode is kept, else to an unconverted draft.
    func resetError(_ id: String) {
        guard let p = papers[id] else { return }
        let next = p.dismissingError()
        papers[id] = next
        persist(id)
    }
    // MARK: Running conversions

    /// Each paper's running conversion (import, rerun, resume or regenerate),
    /// so it can be stopped. The token tells a finished run from a newer one.
    private var runs: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Run `work` as paper `id`'s conversion, tracked so it can be stopped.
    private func startRun(_ id: String, _ work: @escaping @MainActor () async -> Void) {
        let token = UUID()
        let task = Task { @MainActor in
            await work()
            if Task.isCancelled { await markStopped(id) }
            if runs[id]?.token == token { runs[id] = nil }
        }
        runs[id] = (token, task)
    }

    /// Whether paper `id` has a conversion that can be stopped.
    func isRunning(_ id: String) -> Bool { runs[id] != nil }

    /// Stop a paper's conversion. What's already on disk (the script, voiced
    /// sections) is kept, so "Try again" continues from there.
    func stopConversion(_ id: String) {
        guard runs[id] != nil else { return }
        appendLog("Stopping…", paper: id)
        Task { await stopRun(id) }
    }

    /// Cancel `id`'s run, answer any question it's waiting on, and wait for it
    /// to wind down.
    private func stopRun(_ id: String) async {
        guard let run = runs[id] else { return }
        run.task.cancel()
        if pendingCast?.paperId == id { cancelCast() }
        if pendingDuplicate?.incoming.id == id { resolveDuplicate(false) }
        await run.task.value
    }

    /// A stopped run leaves a resumable error (unless it got to the end, or the
    /// import was discarded at the cast or duplicate question).
    private func markStopped(_ id: String) async {
        guard papers[id]?.isDone == false else { return }
        updateRec(id) { $0.state = "error"; $0.statusError = ConversionPresentation.stoppedMessage; $0.message = nil }
        if let stopped = papers[id] { await storage.save(stopped, K.paper(id)) }
        appendLog("Stopped.", paper: id)
    }

    /// Delete a paper and its whole folder, stopping its conversion and playback first.
    func delete(_ id: String) {
        Task {
            // A running conversion would recreate the folder as it writes:
            // stop it and let it wind down first.
            await stopRun(id)
            do {
                if playingPaperId == id { player.stopAll(); playingPaperId = nil }
                // Let queued saves finish first: one writing into the folder
                // while it's being removed made the delete fail.
                await saveQueue?.value
                try await storage.deleteFolder(K.folder(id))
                thumbCache[id] = nil
                if selectedId == id { selectedId = nil }
                papers.removeValue(forKey: id)
            } catch { show(L("Delete failed: {0}", error.localizedDescription)) }
        }
    }

    /// First existing paper (other than `p`) that shares its title or DOI, in any library: a paper
    /// already filed elsewhere still counts.
    func findDuplicate(of p: Paper?) -> Paper? {
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
        while pendingDuplicate != nil, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard !Task.isCancelled else { return false }
        notifier.post(.needsInput(L("Already in your library?")), paperId: incoming.id, title: incoming.displayTitle)
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
    private func askCast(_ id: String, _ proposal: CastProposal, authors: [String], paperTitle: String) async -> CastChoice? {
        while pendingCast != nil, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard !Task.isCancelled else { return nil }
        notifier.post(.needsInput(L("Choose the voices for your episode")), paperId: id, title: paperTitle)
        return await withCheckedContinuation { c in
            pendingCast = CastPrompt(paperId: id, paperTitle: paperTitle, proposals: proposal.speakers, authors: authors,
                                     authorGenders: proposal.authorGenders, cont: c)
        }
    }

    /// Called by the cast sheet: applies the user's names/voices and resumes the
    /// import pipeline. With `voiceAudio` false the script is written but not
    /// voiced (Regenerate audio voices it later, with these voices).
    func resolveCast(_ speakers: [SpeakerConfig], voiceAudio: Bool = true) {
        guard let q = pendingCast else { return }
        player.stopPreview()
        notifier.clearInputRequest(paperId: q.paperId)
        pendingCast = nil
        q.cont.resume(returning: CastChoice(speakers: speakers, voiceAudio: voiceAudio))
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
            try? await storage.delete(K.libraries)
            papers.removeAll()
            libraries = []
            thumbCache.removeAll()
            selectedId = nil
            logEntries = []
            // 2. All settings + old (pre-rename) keys.
            let d = UserDefaults.standard
            for key in ["papertalk.server.json", "papertalk.llm.json", "papertalk.prompts.json", "papertalk.customDepths.json", "papertalk.settingsPage", "papertalk.voiceSpeed", "papertalk.onboarded", LocalStorage.folderDefaultsKey, Localization.defaultsKey, AppStore.askDeleteKey, SpeechSettings.defaultsKey,
                        "paper2pod.server.json", "paper2pod.llm.json", "paper2pod.onboarded"] {
                d.removeObject(forKey: key)
            }
            // 3. API keys in the Keychain (typed key + env-sourced copies).
            //    Voice models are left alone: they have their own button.
            KeychainStore.delete(LLMSettings.typedKeyAccount)
            KeychainStore.delete(SpeechSettings.typedKeyAccount)
            for env in ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY", llm.keyEnv, speech.keyEnv] where !env.isEmpty {
                KeychainStore.delete(env)
            }
            // 4. Back to a clean reactive state.
            config = ServerConfig.load()   // save() re-persists env defaults
            llm = LLMSettings.load()
            speech = SpeechSettings.load()
            askToDeleteListenedAudio = true
            prompts = PromptSettings.defaults
            Localization.language = Localization.load()
            language = Localization.language
            player.voiceSpeed = PlayerController.defaultSpeed
            customPresets = CustomDepthPresets(entries: [])
            if playingPaperId != nil { player.stopAll(); playingPaperId = nil }
            show(L("Cleared data, settings and cache"))
            // Fresh start: close settings and run first-time setup again.
            showSettings = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            showOnboarding = true
        }
    }
    // MARK: Paper bundles and the library folder

    /// Write paper `id` as a `.papertalk` bundle at `url` (replacing what's there): its record,
    /// script, mind map, baked audio and, when `includePDF`, the PDF. Reports as a toast.
    func exportPaper(_ id: String, to url: URL, includePDF: Bool) async {
        guard var paper = papers[id] else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + PaperBundle.pathExtension)
        defer { try? fm.removeItem(at: staging) }
        let turns = await storage.exists(AudioManifest.self, K.audioManifest(id))?.durations.count ?? 0
        paper.hasPdf = paper.hasPdf && includePDF
        do {
            for key in PaperBundle.keys(id, turns: turns, includePDF: paper.hasPdf) {
                let data = key == K.paper(id) ? try JSONEncoder().encode(paper) : try? await storage.read(key)
                guard let data else { continue }
                let file = staging.appendingPathComponent(PaperBundle.relative(key, id))
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: staging, to: url)
            show(L("Exported “{0}”", url.lastPathComponent))
        } catch {
            show(L("Couldn't export the paper: {0}", error.localizedDescription))
        }
    }

    /// Add the paper in the `.papertalk` bundle at `url` to the library and select it. Only the
    /// bundle's known files are read, and each is checked: a script or mind map that doesn't
    /// decode is dropped, and audio comes only with every turn. Returns the new paper's id.
    @discardableResult
    func importPaper(from url: URL) async -> String? {
        let name = url.lastPathComponent
        func file(_ key: String, _ bundleId: String) -> Data? {
            try? Data(contentsOf: url.appendingPathComponent(PaperBundle.relative(key, bundleId)))
        }
        guard let record = try? Data(contentsOf: url.appendingPathComponent("paper.json")),
              let original = try? JSONDecoder().decode(Paper.self, from: record) else {
            show(L("“{0}” isn't a Papertalk paper.", name)); return nil
        }
        let old = original.id
        let id = PaperBundle.importId(old) { papers[$0] != nil }
        func decodable<T: Decodable>(_ type: T.Type, _ key: String) -> Data? {
            file(key, old).flatMap { (try? JSONDecoder().decode(type, from: $0)) != nil ? $0 : nil }
        }
        let transcript = decodable(Transcript.self, K.transcript(old))
        let mindMap = decodable(MindMap.self, K.mindMap(old))
        let pdf = file(K.pdf(old), old)
        var turns: [Data]? = nil
        let manifestData = decodable(AudioManifest.self, K.audioManifest(old))
        if let manifest = manifestData.flatMap({ try? JSONDecoder().decode(AudioManifest.self, from: $0) }) {
            let wavs = manifest.durations.indices.compactMap { file(K.turn(old, $0), old) }
            turns = wavs.count == manifest.durations.count && !wavs.isEmpty ? wavs : nil
        }
        guard transcript != nil || pdf != nil else {
            show(L("“{0}” has neither a script nor a PDF to import.", name)); return nil
        }
        var paper = PaperBundle.imported(original, id: id, hasPdf: pdf != nil, hasScript: transcript != nil,
                                         hasAudio: turns != nil && transcript != nil, hasMindMap: mindMap != nil)
        // The file's library belongs to another library set: it joins the one on screen instead.
        paper.library = shownLibrary
        do {
            if let transcript { try await storage.write(K.transcript(id), transcript) }
            if let mindMap { try await storage.write(K.mindMap(id), mindMap) }
            if let pdf { try await storage.write(K.pdf(id), pdf) }
            if let turns, let manifestData, paper.hasAudio {
                for (i, wav) in turns.enumerated() { try await storage.write(K.turn(id, i), wav) }
                try await storage.write(K.audioManifest(id), manifestData)
            }
            // The record last: the library lists a paper only once its record is there.
            try await storage.write(K.paper(id), JSONEncoder().encode(paper))
        } catch {
            try? await storage.deleteFolder(K.folder(id))
            show(L("Couldn't import “{0}”: {1}", name, error.localizedDescription)); return nil
        }
        papers[id] = paper
        pdfStored(id)
        // Its map's connections to papers in this library are added on their side too.
        if let map = mindMap.flatMap({ try? JSONDecoder().decode(MindMap.self, from: $0) }), !map.externalLinks.isEmpty {
            saveMindMap(id, map)
        }
        selectedId = id
        show(L("Imported “{0}”", paper.displayTitle))
        return id
    }

    /// Files opened from Finder or dropped on the library: every `.papertalk` bundle is imported,
    /// and the first PDF opens in the import sheet. False when none of them is either.
    @discardableResult
    func openFiles(_ urls: [URL]) -> Bool {
        let bundles = urls.filter(PaperBundle.isBundle)
        let pdf = ImportPresentation.firstPDF(in: urls)
        Task { for url in bundles { await importPaper(from: url) } }
        if let pdf { beginImport(pdf) }
        return !bundles.isEmpty || pdf != nil
    }

    /// The local library's folder.
    var libraryFolder: URL { (storage as? LocalStorage)?.root ?? LocalStorage.configuredRoot }

    /// Move the local library into `folder` (nil: back to Application Support) and reload it.
    /// Papers the new folder already holds are kept and join the library.
    func setLibraryFolder(_ folder: URL?) {
        guard isStandalone, activeRun == nil else { return }
        let old = libraryFolder, new = folder ?? LocalStorage.defaultRoot
        guard old.standardizedFileURL != new.standardizedFileURL else { return }
        if playingPaperId != nil { player.stopAll(); playingPaperId = nil }
        Task {
            do {
                _ = try await Task.detached { try LocalStorage.moveLibrary(from: old, to: new) }.value
            } catch {
                show(L("Couldn't move the library: {0}", error.localizedDescription)); return
            }
            if let folder { UserDefaults.standard.set(folder.path, forKey: LocalStorage.folderDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalStorage.folderDefaultsKey) }
            papers.removeAll()
            thumbCache.removeAll()
            selectedId = nil
            refresh()
            show(L("The library is now in “{0}”", new.lastPathComponent))
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
        guard activeRun == nil else { show(L("Wait for conversions to finish first")); return }
        player.stopPreview()
        if playingPaperId != nil { player.stopAll(); playingPaperId = nil }
        for dir in voiceModelDirs { try? FileManager.default.removeItem(at: dir) }
        show(L("Voice models deleted — they'll download again when needed"))
    }

    /// A mind map being drawn outside an import, for the bottom bar's progress pane.
    struct MindMapJob: Equatable {
        var progress: Double
        var message: String
    }
    @Published private(set) var mindMapJobs: [String: MindMapJob] = [:]
    /// Papers whose mind map is being drawn from the detail pane.
    var drawingMindMaps: Set<String> { Set(mindMapJobs.keys) }

    /// Show a mind map being drawn in the bottom bar's progress pane.
    func beginMindMapJob(_ id: String) {
        mindMapJobs[id] = MindMapJob(progress: 0.02, message: L("Reading the PDF…"))
    }

    /// Move a drawing's progress bar or change its line.
    func updateMindMapJob(_ id: String, progress: Double? = nil, message: String? = nil) {
        guard var job = mindMapJobs[id] else { return }
        if let progress { job.progress = progress }
        if let message { job.message = message }
        mindMapJobs[id] = job
    }

    /// The drawing finished or failed: drop it from the progress pane.
    func endMindMapJob(_ id: String) { mindMapJobs[id] = nil }

    /// Whether Create/Redraw mind map is available for `p` right now.
    func canCreateMindMap(_ p: Paper) -> Bool {
        PaperPresentation.canCreateMindMap(p, llmConfigured: !llm.baseUrl.isEmpty, drawing: isDrawingMindMap(p.id))
    }

    /// Draw (or redraw) a paper's mind map from its PDF, outside an import.
    func createMindMap(_ id: String) {
        guard let p = papers[id], canCreateMindMap(p) else { return }
        beginMindMapJob(id)
        Task {
            if await drawMindMapFromPDF(p) { show(L("Mind map ready")) }
        }
    }

    /// The papers Redraw All Mind Maps would draw, oldest first.
    var mindMapsToRedraw: [Paper] {
        papers.values.filter(canCreateMindMap).sorted { ($0.createdIso ?? "") < ($1.createdIso ?? "") }
    }

    /// Menu bar: confirm, then redraw every mind map (each replaces the current one, edits included).
    func requestRedrawAllMindMaps() {
        let count = mindMapsToRedraw.count
        if count > 0 { pendingConfirmation = .redrawAllMindMaps(count) }
    }

    /// Draw every eligible paper's mind map, one after another: each drawing reads and writes the
    /// other maps' connections, so concurrent ones would overwrite each other's.
    func redrawAllMindMaps() {
        let queue = mindMapsToRedraw
        guard !queue.isEmpty else { return }
        for p in queue { beginMindMapJob(p.id) }
        Task {
            var drawn = 0
            for p in queue where await drawMindMapFromPDF(p) { drawn += 1 }
            show(L("Mind maps redrawn: {0} of {1}", drawn, queue.count))
        }
    }

    /// Read the PDF and draw its map, ending the job `beginMindMapJob` started. Returns whether
    /// it was saved; failures are shown, never thrown.
    private func drawMindMapFromPDF(_ p: Paper) async -> Bool {
        let id = p.id
        defer { endMindMapJob(id) }
        guard papers[id] != nil else { return false }   // deleted while queued
        guard let pdfData = try? await storage.read(K.pdf(id)) else { show(L("No PDF to read")); return false }
        let text = await Task.detached { LocalPipeline.extractText(pdfData) }.value
        guard !text.isEmpty else { show(L("Could not read PDF text")); return false }
        updateMindMapJob(id, progress: 0.08, message: L("Asking the LLM for the paper's key concepts…"))
        // Cancelled when the drawing ends (below), so holding the store is fine.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let job = self.mindMapJobs[id] else { return }
                self.updateMindMapJob(id, progress: ImportProgressPresentation.creep(job.progress))
            }
        }
        defer { ticker.cancel() }
        var pipeline = LocalPipeline(baseUrl: llm.baseUrl, apiKey: llm.resolvedKey(),
                                     model: llm.model.isEmpty ? "llama3.1:70b" : llm.model)
        pipeline.prompts = prompts
        pipeline.outputLanguage = p.episodeLanguage
        pipeline.log = { line in Task { @MainActor in self.appendLog(line, paper: id) } }
        guard await drawMindMap(id, text: text, title: p.displayTitle, pipeline: pipeline) else { return false }
        updateMindMapJob(id, progress: 1, message: L("Done"))
        return true
    }

    /// Ask for the mind map and save it. Returns whether it was saved; a
    /// failure is logged and shown, never thrown.
    @discardableResult
    private func drawMindMap(_ id: String, text: String, title: String, pipeline: LocalPipeline) async -> Bool {
        do {
            let map = try await pipeline.mindMap(title: title, text: text)
            await storage.save(map, K.mindMap(id))
            optimistic(id, { $0.hasMindMap = true })
            await connectMindMap(id, map: map, title: title, pipeline: pipeline)
            return true
        } catch {
            if Task.isCancelled { return false }
            appendLog("WARN: mind map failed: \(error.localizedDescription)", paper: id)
            show(L("Couldn't draw the mind map: {0}", error.localizedDescription))
            return false
        }
    }

    /// Find how a newly drawn map connects to the library's other maps (`MindMapConnections`), save
    /// the connections on it, and mirror them onto the other papers' maps (replacing what those
    /// had for this paper). Best-effort: a failure is logged and the map stays as drawn.
    private func connectMindMap(_ id: String, map: MindMap, title: String, pipeline: LocalPipeline) async {
        var others: [String: MindMap] = [:]
        guard let me = papers[id] else { return }
        for p in papers.values where p.id != id && p.hasMindMap == true && Library.linkable(me, p, in: libraries) {
            if let m = await mindMap(for: p.id) { others[p.id] = m }
        }
        guard !others.isEmpty else { return }
        let candidates = MindMapConnections.candidates(for: map, among: others)
        var links: [MindMap.ExternalLink] = []
        if !candidates.isEmpty {
            do {
                links = try await pipeline.mindMapConnections(title: title, map: map, candidates: candidates,
                                                              others: others, titles: papers.mapValues(\.displayTitle))
            } catch {
                if Task.isCancelled { return }
                // Carry on with none: the old connections pointed at the previous drawing's concepts.
                appendLog("WARN: connecting the mind map to other papers failed: \(error.localizedDescription)", paper: id)
            }
        }
        var mine = map
        mine.external = links.isEmpty ? nil : links
        // Papers still holding connections from an earlier drawing of this map lose them.
        saveMindMap(id, mine, involving: Set(others.filter { $0.value.externalLinks.contains { $0.paperId == id } }.keys))
    }

    /// Ask the LLM for the paper's metadata again (fills only empty fields).
    func refreshMeta(_ id: String) {
        Task {
            appendLog("Extracting metadata with LLM…", paper: id)
            guard let pdfData = try? await storage.read(K.pdf(id)) else {
                appendLog("ERROR: no PDF on disk to extract metadata from", paper: id); show(L("No PDF to read")); return
            }
            let text = await Task.detached { LocalPipeline.extractText(pdfData) }.value
            guard !text.isEmpty else { show(L("Could not read PDF text")); return }
            _ = await extractMetaLLM(id, text: text, fallback: papers[id]?.displayTitle ?? "Untitled")
        }
    }

    /// (Re)extract title/authors/affiliations/DOI/tags via the LLM and merge into
    /// the paper only for fields that are empty, keeping hand-edited values.
    /// Returns the extracted metadata once merged (nil if no LLM or it fails).
    private func extractMetaLLM(_ id: String, text: String, fallback: String) async -> PaperMeta? {
        let base = llm.baseUrl
        guard !base.isEmpty else { show(L("Configure an LLM to extract metadata")); return nil }
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
    /// `targetMinutes` is a summary's length (nil: the default); `scriptLanguage`
    /// the language the episode is written in (nil: English); `library` the `Library` it's filed in.
    func upload(_ pdf: Data, filename: String, depth: Depth, depthNote: String, targetMinutes: Int? = nil,
                scriptLanguage: AppLanguage? = nil, library: String? = nil) {
        let id = UUID().uuidString
        startRun(id) {
            await self.runPipeline(nil, id: id, pdf: pdf, filename: filename, depth: depth, depthNote: depthNote,
                                   targetMinutes: targetMinutes, scriptLanguage: scriptLanguage, library: library)
        }
    }

    // MARK: Audio baking

    /// Render a transcript to per-turn WAVs with the speech backend and store them under
    /// the paper's `turns/` keys. Reports download + per-turn progress across
    /// the given [start, end] band of the unified pipeline bar. Returns nil on
    /// success (hasAudio = true), otherwise a message for the user. Turns already
    /// on disk are reused, so running it again continues where it stopped.
    private func bakeAudio(_ id: String, _ transcript: Transcript, from start: Double, to end: Double) async -> String? {
        let flat = transcript.segments.flatMap { $0.turns }
        guard !flat.isEmpty else { return L("The script has nothing to read.") }
        let total = flat.count
        func map(_ f: Double) -> Double { start + (end - start) * f }
        if audioGate.isBusy {
            updateRec(id) { $0.stage = "audio"; $0.progress = map(0.0); $0.message = L("Waiting for another paper's audio…") }
        }
        guard await audioGate.acquire() else { return L("Stopped.") }
        defer { audioGate.release() }
        let backend = speechBackend
        let share = backend.preparationShare
        updateRec(id) { $0.stage = "audio"; $0.progress = map(0.0); $0.message = backend.preparingMessage }

        do {
            // Local Kokoro downloads its model here, on the first part of the band.
            try await backend.prepare { [weak self] fraction, phase in
                Task { @MainActor in
                    self?.updateRec(id) { $0.stage = "audio"; $0.progress = map(fraction * share); $0.message = phase }
                }
            }

            let voiceMap = castVoices(for: id, speakers: flat.map { $0.speaker })
            let speed = Float(player.voiceSpeed)
            // Resume: reuse every turn already baked on disk instead of voicing it again.
            var wavs: [Data?] = []
            for i in 0..<total { wavs.append(try? await storage.read(K.turn(id, i))) }
            let todo = (0..<total).filter { wavs[$0] == nil }
            var done = total - todo.count
            func report() {
                let frac = share + (1 - share) * Double(done) / Double(total)
                updateRec(id) { $0.stage = "audio"; $0.progress = map(frac); $0.message = L("Synthesizing section {0}/{1}…", done, total) }
            }
            if done > 0 { report() }

            // A speech server takes several turns at once; local Kokoro one.
            // Turns are saved as they finish, so a stop or failure resumes cleanly.
            func job(_ i: Int) -> @Sendable () async throws -> (Int, Data) {
                let text = flat[i].text
                let voice = voiceMap[flat[i].speaker] ?? KokoroSpeech.defaultVoice
                return {
                    do { return (i, try await backend.speak(text, voice: voice, speed: speed)) }
                    catch { throw TurnFailure(index: i, underlying: error) }
                }
            }
            let width = max(1, backend.parallelRequests)
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for i in todo.prefix(width) { group.addTask(operation: job(i)) }
                var queued = min(width, todo.count)
                while let (i, wav) = try await group.next() {
                    do { try await storage.write(K.turn(id, i), wav) } catch { throw TurnFailure(index: i, underlying: error) }
                    wavs[i] = wav
                    done += 1
                    report()
                    if queued < todo.count { group.addTask(operation: job(todo[queued])); queued += 1 }
                }
            }
            let durations = wavs.map { KokoroSpeech.wavDuration($0 ?? Data()) }
            await storage.save(AudioManifest(durations: durations), K.audioManifest(id))
            return nil
        } catch {
            let failure = error as? TurnFailure
            let cause = failure?.underlying ?? error
            if cause is CancellationError || Task.isCancelled { return L("Stopped.") }
            let at = failure?.index ?? 0
            appendLog("Audio synthesis failed at section \(at + 1)/\(total): \(cause.localizedDescription)", paper: id)
            return L("Voicing stopped at section {0} of {1} ({2}). Try again to continue from there.", at + 1, total, cause.localizedDescription)
        }
    }

    /// Which turn a bake failed on, around the error itself.
    private struct TurnFailure: Error {
        let index: Int
        let underlying: Error
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
            show(PaperPresentation.liveAudioToast)
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
                    self.episodeFinished(id)
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
        guard let p = papers[id], p.hasScript else { show(L("No transcript to speak")); return }
        guard !p.isActive else { return }
        notifier.requestPermissionIfNeeded()
        startRun(id) { [self] in
            guard let t = await transcript(for: id) else { show(L("No transcript on disk")); return }
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
                updateRec(id) { $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = L("Done"); $0.hasAudio = true }
                if let done = papers[id] { await storage.save(done, K.paper(id)) }
                appendLog("Audio regenerated.", paper: id)
                show(L("Audio regenerated"))
                await prepareAudio(for: id)
            }
        }
    }

    // MARK: Pipeline (always local)
    /// The whole import (or a rerun or resume when `existing` is given): store the PDF, read its
    /// text, then metadata, the duplicate and cast questions, the script, the mind map and the audio.
    /// Each step's result is saved as it lands, so a stopped or quit run resumes from there.
    private func runPipeline(_ existing: Paper?, id newId: String? = nil, pdf: Data? = nil, filename: String = "",
                             depth: Depth = .inDepth, depthNote: String = "", targetMinutes: Int? = nil,
                             scriptLanguage: AppLanguage? = nil, library: String? = nil) async {
        let id = existing?.id ?? newId ?? UUID().uuidString
        // First conversion is when notifications start to matter: ask then.
        notifier.requestPermissionIfNeeded()
        let name = filename.isEmpty ? (existing?.filename ?? "Paper") : filename

        var rec = existing ?? Paper(id: id, title: "", filename: name, hasPdf: true, hasScript: false, hasAudio: false,
                                     createdIso: ISO8601DateFormatter().string(from: Date()), publishedIso: existing?.publishedIso, state: "queued",
                                     tags: [], favorite: false, authors: [], affiliations: [], doi: "", read: false,
                                     depth: existing?.depth ?? depth.rawValue, bibtex: nil, targetMinutes: targetMinutes, progress: 0, duration: 0, progressTs: nil,
                                     stage: "extract", message: L("Queued"), statusError: nil)
        if existing == nil, let scriptLanguage, scriptLanguage != .english { rec.scriptLanguage = scriptLanguage.rawValue }
        if existing == nil { rec.library = library }
        papers[id] = rec
        selectedId = id
        // Store the PDF right away: the record already says hasPdf, and the
        // library shows its cover as soon as the file exists. Saved beside the
        // queue, so the place in line is taken before anything is awaited.
        let saved = Task { [rec] in
            await storage.save(rec, K.paper(id))
            if let pdf {
                try? await storage.write(K.pdf(id), pdf)
                pdfStored(id)
            }
        }
        appendLog("Queued: \(name)", paper: id)

        if importGate.isBusy { updateRec(id) { $0.state = "queued"; $0.message = L("Queued") } }
        let admitted = await importGate.acquire()
        await saved.value
        guard admitted else { return }
        var holdsGate = true
        defer { if holdsGate { importGate.release() } }
        // Hand the queue to the next import before voicing (that waits on `audioGate`).
        func leaveQueue() { importGate.release(); holdsGate = false }

        let base = llm.baseUrl
        let key = llm.resolvedKey()
        let model = llm.model.isEmpty ? "llama3.1:70b" : llm.model

        let pdfData: Data
        if let pdf {
            pdfData = pdf
        } else if let stored = try? await storage.read(K.pdf(id)) {
            pdfData = stored
        } else {
            updateRec(id) { $0.state = "error"; $0.statusError = L("No PDF") }; appendLog("ERROR: No PDF to convert", paper: id); return
        }
        var pipeline = LocalPipeline(baseUrl: base, apiKey: key, model: model)
        pipeline.prompts = prompts
        pipeline.outputLanguage = rec.episodeLanguage
        pipeline.log = { [weak self] line in Task { @MainActor in self?.appendLog(line, paper: id) } }
        // Transcript writing spans 0.10 → 0.75 of the unified pipeline bar.
        pipeline.onProgress = { [weak self] frac, label in
            Task { @MainActor in self?.updateRec(id) { $0.progress = 0.10 + 0.65 * frac; $0.message = label } }
        }

        updateRec(id) { $0.state = "running"; $0.stage = "extract"; $0.progress = 0.02; $0.message = L("Extracting text…") }
        appendLog("Extracting PDF text…", paper: id)
        let text = await Task.detached { LocalPipeline.extractText(pdfData) }.value
        guard !text.isEmpty else {
            updateRec(id) { $0.state = "error"; $0.statusError = L("Could not read PDF text") }; appendLog("ERROR: Could not read PDF text", paper: id); return
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
            updateRec(id) { $0.stage = "audio"; $0.progress = 0.78; $0.message = L("Synthesizing audio…") }
            leaveQueue()
            if let failure = await bakeAudio(id, direct, from: 0.80, to: 1.0) {
                await storage.save(direct, K.transcript(id))
                await failAudio(id, failure)
                return
            }
            await finish(id, direct, name, authors: [], pdfData: pdfData, depth: depth, hasAudio: true)
            return
        }

        // Cleared when the user skips audio at the cast prompt.
        var voiceAudio = true

        // Fill title/authors/DOI/tags from the LLM right away (before the script),
        // so the detail view shows real metadata even while the episode is being written.
        if !base.isEmpty {
            _ = await extractMetaLLM(id, text: text, fallback: name)
            // Duplicate-import guard: if an existing paper already has this title
            // or DOI, let the user decide before spending LLM + TTS time on it.
            if existing == nil, let dup = findDuplicate(of: papers[id]),
               !(await askDuplicate(papers[id]!, duplicateOf: dup)) {
                await discardImport(id)
                show(L("Skipped import — already have “{0}”", dup.displayTitle))
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
            let choice = hasScript ? CastChoice(speakers: [], voiceAudio: true)
                : await askCast(id, proposal, authors: papers[id]?.authors ?? rec.authors,
                                paperTitle: papers[id]?.displayTitle ?? rec.displayTitle)
            guard let choice else {
                await discardImport(id)
                show(L("Import cancelled"))
                return
            }
            voiceAudio = choice.voiceAudio
            let cast = choice.speakers
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

        updateRec(id) { $0.state = "running"; $0.stage = "segments"; $0.progress = 0.08; $0.message = L("Planning episode…") }
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
                                                                    summaryMinutes: rec.targetMinutes,
                                                                    host: rec.speakers.first?.name,
                                                                    expert: rec.speakers.count > 1 ? rec.speakers[1].name : nil)
                script = result.transcript
                // Persist now so an interrupted run can resume past segments later.
                await storage.save(script, K.transcript(id))
                appendLog("Got transcript (\(script.segments.count) segments)", paper: id)
            }
            // Best-effort: a mind map that fails doesn't fail the episode (Create mind map retries).
            if papers[id]?.hasMindMap != true {
                updateRec(id) { $0.stage = Paper.mindMapStage; $0.progress = 0.76; $0.message = L("Asking the LLM for the paper's key concepts…") }
                await drawMindMap(id, text: text, title: papers[id]?.displayTitle ?? name, pipeline: pipeline)
            }
            guard voiceAudio else {
                appendLog("Skipped audio — voice the script later with Regenerate audio.", paper: id)
                await finish(id, script, papers[id]?.displayTitle ?? name,
                             authors: papers[id]?.authors ?? [], pdfData: pdfData, depth: depth, hasAudio: false)
                return
            }
            updateRec(id) { $0.stage = "audio"; $0.progress = 0.78; $0.message = L("Synthesizing audio…") }
            leaveQueue()
            if let failure = await bakeAudio(id, script, from: 0.80, to: 1.0) {
                await failAudio(id, failure)
                return
            }
            await finish(id, script, papers[id]?.displayTitle ?? name,
                         authors: papers[id]?.authors ?? [], pdfData: pdfData, depth: depth, hasAudio: true)
        } catch {
            // Stopped: the run's wrapper records that (`markStopped`), not a failure.
            if Task.isCancelled { return }
            updateRec(id) { $0.state = "error"; $0.statusError = error.localizedDescription }
            appendLog("ERROR: \(error.localizedDescription)", paper: id)
            show(L("Conversion failed: {0}", error.localizedDescription))
        }
    }

    /// Pick up an import a quit left unfinished.
    private func resumePipeline(_ id: String) async {
        guard let existing = papers[id] else { return }
        let depth = Depth(rawValue: existing.depth ?? "") ?? .inDepth
        appendLog("Resuming import of \(existing.displayTitle)…", paper: id)
        await runPipeline(existing, depth: depth)
    }

    /// Save the script and mark the paper done (`hasAudio` says whether it was voiced).
    private func finish(_ id: String, _ t: Transcript, _ title: String, authors: [String], pdfData: Data?, depth: Depth = .inDepth, hasAudio: Bool) async {
        await storage.save(t, K.transcript(id))
        if let pdfData, !pdfData.isEmpty { try? await storage.write(K.pdf(id), pdfData) }
        updateRec(id) {
            $0.state = "done"; $0.stage = "done"; $0.progress = 1; $0.message = L("Done")
            $0.hasScript = true; $0.hasAudio = hasAudio
            $0.title = $0.title ?? title
            $0.authors = authors.isEmpty ? $0.authors : authors
            $0.depth = depth.rawValue
        }
        if let done = papers[id] { await storage.save(done, K.paper(id)) }
        appendLog("Done: \(title)", paper: id)
        show(L("Converted"))
    }

    /// Change a paper in memory without saving (progress ticks), posting a notification when a run ends.
    private func updateRec(_ id: String, _ mutate: (inout Paper) -> Void) {
        guard var p = papers[id] else { return }
        let wasActive = p.isActive
        mutate(&p)
        papers[id] = p
        // A run just ended: tell the user if they're in another app.
        if wasActive && p.isDone {
            notifier.post(.ready, paperId: id, title: p.displayTitle)
        } else if wasActive && p.isError {
            notifier.post(.failed(p.statusError ?? L("Something went wrong")), paperId: id, title: p.displayTitle)
        }
    }

    /// Bring a paper into view and select it (e.g. from a notification).
    func reveal(_ id: String) {
        guard papers[id] != nil else { return }
        if !filteredPapers().contains(where: { $0.id == id }) {
            view = .all; activeTag = nil; activeAuthor = nil; activeLibrary = nil
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

    /// Ask GitHub for the newest release on `channel` and show the result as an alert.
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

    /// Close the update alert and open its release page.
    func openUpdateLink(_ alert: UpdateAlert) {
        updateAlert = nil
        if let link = alert.link { NSWorkspace.shared.open(link) }
    }

    /// Show a toast for a few seconds; a newer one replaces it.
    func show(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    /// Save the import sheet's custom depth as a named preset (same name: replaced).
    func saveCustomPreset(name: String, text: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanText.isEmpty else { return }
        var entries = customPresets.entries.filter { $0.name != cleanName }
        entries.append(.init(name: cleanName, text: cleanText))
        customPresets = CustomDepthPresets(entries: entries)
        customPresets.save()
        show(L("Saved prompt “{0}”", cleanName))
    }

    /// Select a paper (nil: none).
    func select(_ id: String?) { selectedId = id }
}

/// The library's sort orders (wording in `SortOption.label`).
enum SortOption: String, CaseIterable, Identifiable {
    case newest, oldest, title = "Title", recent = "Recently converted"
    var id: String { rawValue }
}

/// Covers in a grid, or rows in a list.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid = "Grid", list = "List"
    var id: String { rawValue }
}