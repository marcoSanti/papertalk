import XCTest
@testable import Papertalk

/// `AppStore` against a temp-folder library. Nothing here starts a conversion
/// (that would call the LLM / Kokoro); papers are seeded on disk or in memory.
@MainActor
final class AppStoreTests: PapertalkTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storage: LocalStorage!

    override func setUp() {
        super.setUp()
        dir = Fixtures.tempDir()
        storage = LocalStorage(root: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A store over the temp library holding `papers`. Finished papers are
    /// written to disk and loaded by the store's own startup scan, exactly like
    /// the app (the scan drops anything that's only in memory). Papers that are
    /// mid-conversion are added in memory afterwards: on disk the scan would
    /// resume them, which would call the LLM.
    private func makeStore(_ papers: [Paper] = []) async -> AppStore {
        let onDisk = papers.filter { !$0.isActive }
        for p in onDisk { await storage.save(p, K.paper(p.id)) }
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == onDisk.count }
        for p in papers where p.isActive { store.papers[p.id] = p }
        return store
    }

    private func onDisk(_ id: String) async -> Paper? {
        await storage.exists(Paper.self, K.paper(id))
    }

    // MARK: loading

    func testRefreshLoadsOnlyFoldersWithPaperRecord() async throws {
        let a = Fixtures.paper(id: "a", title: "Alpha")
        await storage.save(a, K.paper("a"))
        try await storage.write("papers/orphan/turns/0.wav", Fixtures.silentWAV(seconds: 0.1))

        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == 1 }
        XCTAssertEqual(store.papers["a"]?.title, "Alpha")
        XCTAssertNil(store.papers["orphan"])
    }

    func testIsStandaloneFollowsInjectedStorage() async {
        let local = await makeStore()
        XCTAssertTrue(local.isStandalone)

        // The remote store scans its server on startup: answer it with an empty library.
        var listed = false
        MockLLM.install { request in
            listed = request.url?.host == "mock.local"
            return (200, Data("[]".utf8))
        }
        let remote = AppStore(storage: HttpStorage(apiBase: "http://mock.local", token: ""))
        XCTAssertFalse(remote.isStandalone)
        await waitUntil { listed }
    }

    // MARK: filtering, search, sort

    private var library: [Paper] {
        [
            Fixtures.paper(id: "1", title: "Graph Networks", createdIso: "2024-03-01T00:00:00Z",
                           tags: ["gnn", "ml"], favorite: true, authors: ["Ada Lovelace"], doi: "10.1/gnn"),
            Fixtures.paper(id: "2", title: "Attention", state: "running", createdIso: "2024-01-01T00:00:00Z",
                           tags: ["nlp"], authors: ["Grace Hopper", "Ada Lovelace"]),
            Fixtures.paper(id: "3", title: "Bayesian Things", state: "queued", createdIso: "2024-02-01T00:00:00Z",
                           tags: ["ml"], authors: ["Alan Turing"]),
            Fixtures.paper(id: "4", title: "Compilers", state: "error", createdIso: "2023-12-01T00:00:00Z",
                           authors: ["Grace Hopper"]),
        ]
    }

    private func ids(_ papers: [Paper]) -> [String] { papers.map(\.id) }

    func testDefaultViewSortsNewestFirst() async {
        let store = await makeStore(library)
        XCTAssertEqual(ids(store.filteredPapers()), ["1", "3", "2", "4"])
    }

    func testSortOptions() async {
        let store = await makeStore(library)
        store.sort = .oldest
        XCTAssertEqual(ids(store.filteredPapers()), ["4", "2", "3", "1"])
        store.sort = .title
        XCTAssertEqual(ids(store.filteredPapers()), ["2", "3", "4", "1"])
        store.sort = .recent   // finished papers first, then newest
        XCTAssertEqual(ids(store.filteredPapers()).first, "1")
    }

    func testFavoritesTagAndAuthorScopes() async {
        let store = await makeStore(library)
        store.view = .fav
        XCTAssertEqual(ids(store.filteredPapers()), ["1"])

        store.view = .tag; store.activeTag = "ml"
        XCTAssertEqual(Set(ids(store.filteredPapers())), ["1", "3"])

        store.view = .author; store.activeAuthor = "Ada Lovelace"
        XCTAssertEqual(Set(ids(store.filteredPapers())), ["1", "2"])
    }

    func testConvertingFilterIncludesQueued() async {
        let store = await makeStore(library)
        store.statusFilter = "running"
        XCTAssertEqual(Set(ids(store.filteredPapers())), ["2", "3"])
        store.statusFilter = "error"
        XCTAssertEqual(ids(store.filteredPapers()), ["4"])
        store.statusFilter = "done"
        XCTAssertEqual(ids(store.filteredPapers()), ["1"])
    }

    func testSearchMatchesTitleAuthorDOIAndTags() async {
        let store = await makeStore(library)
        store.search = "graph"
        XCTAssertEqual(ids(store.filteredPapers()), ["1"])
        store.search = "turing"                   // author
        XCTAssertEqual(ids(store.filteredPapers()), ["3"])
        store.search = "10.1/gnn"                 // DOI
        XCTAssertEqual(ids(store.filteredPapers()), ["1"])
        store.search = "#nl"                      // tag-only search
        XCTAssertEqual(ids(store.filteredPapers()), ["2"])
        store.search = "#"                        // bare hash matches nothing
        XCTAssertTrue(store.filteredPapers().isEmpty)
        store.search = "   "                      // whitespace is no search
        XCTAssertEqual(store.filteredPapers().count, 4)
    }

    func testTagCountsAreSortedAndDeduplicated() async {
        var p = Fixtures.paper(id: "dup", tags: ["ml", "ml"])
        p.title = "Dup"
        let store = await makeStore(library + [p])
        let counts = Dictionary(uniqueKeysWithValues: store.tagCounts)
        XCTAssertEqual(counts["ml"], 3)           // a paper's duplicate tag counts once
        XCTAssertEqual(store.tagCounts.map(\.0), store.tagCounts.map(\.0).sorted())
    }

    // MARK: authors

    func testPapersByAuthorNormalizesWhitespaceAndSortsNewestFirst() async {
        let store = await makeStore([
            Fixtures.paper(id: "old", createdIso: "2020-01-01T00:00:00Z", authors: ["Ada  Lovelace "]),
            Fixtures.paper(id: "new", createdIso: "2024-01-01T00:00:00Z", authors: ["Ada Lovelace"]),
            Fixtures.paper(id: "blank", authors: ["   "]),
        ])
        XCTAssertEqual(store.papersByAuthor.keys.sorted(), ["Ada Lovelace"])
        XCTAssertEqual(store.papersByAuthor["Ada Lovelace"]?.map(\.id), ["new", "old"])
        XCTAssertEqual(store.authorCounts.first?.1, 2)
    }

    func testShowAuthorScopesLibraryAndClearsHiddenSelection() async {
        let store = await makeStore(library)
        store.selectedId = "3"                    // Turing's paper
        store.activeTag = "ml"
        store.showAuthor("  Ada   Lovelace ")
        XCTAssertEqual(store.view, .author)
        XCTAssertEqual(store.activeAuthor, "Ada Lovelace")
        XCTAssertNil(store.activeTag)
        XCTAssertNil(store.selectedId)            // not by Ada, so deselected
        store.selectedId = "1"
        store.showAuthor("Ada Lovelace")
        XCTAssertEqual(store.selectedId, "1")     // still in scope, kept
    }

    func testRevealResetsFiltersThatHideThePaper() async {
        let store = await makeStore(library)
        store.view = .fav; store.search = "nothing matches"; store.statusFilter = "error"
        store.reveal("3")
        XCTAssertEqual(store.selectedId, "3")
        XCTAssertEqual(store.view, .all)
        XCTAssertEqual(store.search, "")
        XCTAssertEqual(store.statusFilter, "all")
        store.reveal("missing")
        XCTAssertEqual(store.selectedId, "3")     // unknown id is ignored
    }

    // MARK: edits persist to disk

    func testToggleFavoriteAndReadPersist() async {
        let p = Fixtures.paper(id: "p")
        let store = await makeStore([p])
        store.toggleFavorite("p")
        store.toggleRead("p")
        XCTAssertEqual(store.papers["p"]?.favorite, true)
        await waitUntil {
            let saved = await self.onDisk("p")
            return saved?.favorite == true && saved?.read == true
        }
        store.toggleRead("p", force: true)
        XCTAssertEqual(store.papers["p"]?.read, true)   // force keeps it set
    }

    func testSaveTitleCleansWhitespaceAndRejectsEmpty() async {
        let store = await makeStore([Fixtures.paper(id: "p", title: "Old")])
        store.saveTitle("p", "  New \n  Title ")
        XCTAssertEqual(store.papers["p"]?.title, "New Title")
        await waitUntil { await self.onDisk("p")?.title == "New Title" }
        store.saveTitle("p", "   ")
        XCTAssertEqual(store.papers["p"]?.title, "New Title")
        XCTAssertEqual(store.toast, "Title cannot be empty")
    }

    func testTagsAreCleanedDeduplicatedAndRemovable() async {
        let store = await makeStore([Fixtures.paper(id: "p")])
        store.addTag("p", "  machine   learning ")
        store.addTag("p", "machine_learning")     // duplicate after cleaning
        store.addTag("p", "  ")
        XCTAssertEqual(store.papers["p"]?.tags, ["machine_learning"])
        store.removeTag("p", "machine_learning")
        XCTAssertEqual(store.papers["p"]?.tags, [])
        await waitUntil { await self.onDisk("p")?.tags == [] }
    }

    func testSaveEditableMetaTrimsAndDropsBlankLines() async {
        let store = await makeStore([Fixtures.paper(id: "p")])
        store.saveEditableMeta("p", title: " T ", filename: " f.pdf ", authors: ["Ada", " ", " Grace "],
                               affiliations: ["", "UCL"], doi: " 10.1/x ")
        let p = store.papers["p"]
        XCTAssertEqual(p?.title, "T")
        XCTAssertEqual(p?.filename, "f.pdf")
        XCTAssertEqual(p?.authors, ["Ada", "Grace"])
        XCTAssertEqual(p?.affiliations, ["UCL"])
        XCTAssertEqual(p?.doi, "10.1/x")
        await waitUntil { await self.onDisk("p")?.doi == "10.1/x" }
    }

    func testSaveProgressPersists() async {
        let store = await makeStore([Fixtures.paper(id: "p")])
        store.saveProgress("p", 42, 600)
        await waitUntil { await self.onDisk("p")?.progress == 42 }
        XCTAssertEqual(store.papers["p"]?.duration, 600)
    }

    func testRapidEditsAlwaysLeaveTheLatestStateOnDisk() async {
        // Regression: each edit used to save its own snapshot on a separate
        // task, so an older snapshot could land last and undo a newer edit.
        let store = await makeStore([Fixtures.paper(id: "p")])
        for i in 0..<25 {
            store.toggleFavorite("p")
            store.addTag("p", "t\(i)")
        }
        store.toggleRead("p")
        let expected = store.papers["p"]
        await waitUntil { await self.onDisk("p") == expected }
    }

    // MARK: delete

    func testDeleteRemovesTheWholeFolder() async throws {
        let p = Fixtures.paper(id: "p")
        await storage.save(p, K.paper("p"))
        try await storage.write(K.pdf("p"), Data("pdf".utf8))
        try await storage.write(K.turn("p", 0), Fixtures.silentWAV(seconds: 0.1))
        try await storage.write("papers/p/unknown-extra-file.bin", Data([1]))   // not in any key list
        let store = await makeStore([p])
        store.selectedId = "p"

        store.delete("p")
        await waitUntil { store.papers["p"] == nil }
        XCTAssertNil(store.selectedId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("papers/p").path))
    }

    func testPendingSaveDoesNotResurrectADeletedPaper() async {
        let store = await makeStore([Fixtures.paper(id: "p")])
        store.toggleFavorite("p")                 // queues a save
        store.delete("p")
        await waitUntil { store.papers["p"] == nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("papers/p").path))
    }

    func testDeleteWorksOnAPaperMarkedConverting() async {
        let store = await makeStore([Fixtures.paper(id: "p", state: "running")])
        store.delete("p")
        await waitUntil { store.papers["p"] == nil }
    }

    // MARK: errors and reruns

    func testDismissErrorWithScriptGoesBackToDone() async {
        var p = Fixtures.paper(id: "p", state: "error", hasScript: true)
        p.statusError = "boom"
        let store = await makeStore([p])
        store.resetError("p")
        XCTAssertEqual(store.papers["p"]?.state, "done")
        XCTAssertNil(store.papers["p"]?.statusError)
        await waitUntil { await self.onDisk("p")?.state == "done" }
    }

    func testDismissErrorWithoutScriptBecomesNotConverted() async {
        let store = await makeStore([Fixtures.paper(id: "p", state: "error", hasScript: false, hasAudio: false)])
        store.resetError("p")
        XCTAssertEqual(store.papers["p"]?.state, "draft")
        XCTAssertFalse(store.papers["p"]!.isActive)   // must not look like it's converting
    }

    func testRerunAndRegenerateAreNoOpsWhileConverting() async {
        let p = Fixtures.paper(id: "p", state: "running")
        let store = await makeStore([p])
        store.rerun("p")
        store.regenerateAudio("p")
        XCTAssertEqual(store.papers["p"], p)          // nothing touched, no pipeline started
    }

    func testRegenerateWithoutScriptExplains() async {
        let store = await makeStore([Fixtures.paper(id: "p", hasScript: false)])
        store.regenerateAudio("p")
        XCTAssertEqual(store.toast, "No transcript to speak")
    }

    // MARK: voices and audio

    func testCastVoicesPreferConfiguredCastAndKeepOthersDistinct() async {
        let store = await makeStore([Fixtures.paper(id: "p", speakers: [SpeakerConfig(name: "William", voice: "am_puck")])])
        let map = store.castVoices(for: "p", speakers: ["Jordan", "William", "Jordan", "Guest"])
        XCTAssertEqual(map["William"], "am_puck")
        XCTAssertEqual(Set(map.keys), ["Jordan", "William", "Guest"])
        XCTAssertNotEqual(map["Jordan"], map["Guest"])
    }

    // MARK: deleting audio

    /// A finished paper with a script and two voiced turns on disk.
    private func storeWithBakedAudio() async throws -> AppStore {
        let store = await makeStore([Fixtures.paper(id: "p", hasScript: true, hasAudio: true)])
        await storage.save(Fixtures.transcript([("Jordan", "Hi"), ("Ada", "Hello")]), K.transcript("p"))
        await storage.save(AudioManifest(durations: [0.5, 0.25]), K.audioManifest("p"))
        try await storage.write(K.turn("p", 0), Fixtures.silentWAV(seconds: 0.5))
        try await storage.write(K.turn("p", 1), Fixtures.silentWAV(seconds: 0.25))
        return store
    }

    func testDeleteAudioKeepsTheScript() async throws {
        let store = try await storeWithBakedAudio()
        store.deleteAudio("p")
        await waitUntil { store.papers["p"]?.hasAudio == false }
        await waitUntil { await self.onDisk("p")?.hasAudio == false }
        let manifest = await storage.exists(AudioManifest.self, K.audioManifest("p"))
        XCTAssertNil(manifest)
        let turn = try? await storage.read(K.turn("p", 0))
        XCTAssertNil(turn)
        let script = await storage.exists(Transcript.self, K.transcript("p"))
        XCTAssertNotNil(script)
        XCTAssertTrue(PaperPresentation.isPlayable(store.papers["p"]!))   // live voices still play it
        XCTAssertEqual(store.toast, "Audio deleted")
    }

    func testDeleteAudioWaitsForAConversion() async {
        let store = await makeStore([Fixtures.paper(id: "p", state: "running", hasAudio: true)])
        store.deleteAudio("p")   // refused on the spot: nothing is started
        XCTAssertEqual(store.papers["p"]?.hasAudio, true)
        XCTAssertNil(store.toast)
    }

    func testFinishingAnEpisodeAsksAboutItsAudio() async throws {
        let store = try await storeWithBakedAudio()
        defer { store.askToDeleteListenedAudio = true }
        store.trackPlayback()
        store.playingPaperId = "p"
        store.player.didEnd = true
        await waitUntil { store.pendingConfirmation != nil }
        guard case .finishedListening(let asked)? = store.pendingConfirmation else { return XCTFail("no question") }
        XCTAssertEqual(asked.id, "p")
        XCTAssertEqual(store.papers["p"]?.read, true)

        // "Delete audio"
        store.confirmPending(.finishedListening(asked))
        await waitUntil { store.papers["p"]?.hasAudio == false }
        XCTAssertNil(store.pendingConfirmation)
    }

    func testFinishingDoesNotAskWithoutAudioOrWhenTurnedOff() async throws {
        let store = try await storeWithBakedAudio()
        defer { store.askToDeleteListenedAudio = true }
        // "Keep, and don't ask again"
        store.episodeFinished("p")
        store.confirmSecondary(store.pendingConfirmation!)
        XCTAssertFalse(store.askToDeleteListenedAudio)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppStore.askDeleteKey) as? Bool, false)
        store.episodeFinished("p")
        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(store.papers["p"]?.hasAudio, true)   // kept

        store.askToDeleteListenedAudio = true
        store.papers["p"]?.hasAudio = false
        store.episodeFinished("p")
        XCTAssertNil(store.pendingConfirmation)              // nothing to delete
    }

    func testLoadBakedAudioNeedsEveryTurn() async throws {
        let store = await makeStore([Fixtures.paper(id: "p")])
        await storage.save(AudioManifest(durations: [0.5, 0.25]), K.audioManifest("p"))
        try await storage.write(K.turn("p", 0), Fixtures.silentWAV(seconds: 0.5))
        let partial = await store.loadBakedAudio(for: "p")
        XCTAssertNil(partial)                          // turn 1 missing → not playable as baked

        try await storage.write(K.turn("p", 1), Fixtures.silentWAV(seconds: 0.25))
        let baked = await store.loadBakedAudio(for: "p")
        XCTAssertEqual(baked?.map(\.duration), [0.5, 0.25])
    }

    func testPrepareAudioUsesBakedAudioWithoutSynthesis() async throws {
        let store = await makeStore([Fixtures.paper(id: "p")])
        await storage.save(Fixtures.transcript([("Jordan", "Hi"), ("Ada", "Hello")]), K.transcript("p"))
        await storage.save(AudioManifest(durations: [0.5, 0.25]), K.audioManifest("p"))
        try await storage.write(K.turn("p", 0), Fixtures.silentWAV(seconds: 0.5))
        try await storage.write(K.turn("p", 1), Fixtures.silentWAV(seconds: 0.25))

        await store.prepareAudio(for: "p")
        XCTAssertEqual(store.playingPaperId, "p")
        XCTAssertEqual(store.player.turnCount, 2)
        XCTAssertFalse(store.player.isRendering)       // baked: nothing to render
        XCTAssertEqual(store.player.renderedCount, 2)
    }

    func testPrepareAudioWithoutTranscriptUnloadsPlayer() async {
        let store = await makeStore([Fixtures.paper(id: "p")])
        await store.prepareAudio(for: "p")
        XCTAssertEqual(store.player.turnCount, 0)
    }

    // MARK: logic moved out of the views

    func testSidebarSelectionRoundTrips() async {
        let store = await makeStore(library)
        XCTAssertEqual(store.sidebarSelection, .all)
        store.selectSidebar(.favorites)
        XCTAssertEqual(store.view, .fav)
        store.showTag("ml")
        XCTAssertEqual(store.sidebarSelection, .tag("ml"))
        XCTAssertEqual(store.activeTag, "ml")
        store.showAuthor("Ada Lovelace")
        XCTAssertEqual(store.sidebarSelection, .authors)   // one author keeps "Authors" highlighted
        store.selectSidebar(.all)
        XCTAssertNil(store.activeAuthor)
        XCTAssertNil(store.activeTag)
    }

    func testSidebarItemsAndCounts() async {
        let store = await makeStore([
            Fixtures.paper(id: "a", tags: ["nlp", "vision"], favorite: true, authors: ["Ada Lovelace"]),
            Fixtures.paper(id: "b", tags: ["nlp"], authors: ["Ada Lovelace", "Grace Hopper"]),
        ])
        XCTAssertEqual(store.sidebarItems, [.all, .favorites, .authors, .tag("nlp"), .tag("vision")])
        XCTAssertEqual(store.sidebarItems.map(store.sidebarCount), [2, 1, 2, 2, 1])
        XCTAssertEqual(store.sidebarCount(.tag("missing")), 0)
    }

    func testSidebarKeepsOrDropsTheSelectedPaper() async {
        let store = await makeStore(library)
        store.selectedId = "1"                            // favourite, tagged ml
        store.selectSidebar(.favorites)
        XCTAssertEqual(store.selectedId, "1")
        store.selectSidebar(.tag("nlp"))
        XCTAssertNil(store.selectedId)                    // not tagged nlp
    }

    func testStatusCountsFollowTheScopeNotTheSearch() async {
        let store = await makeStore(library)
        store.search = "graph"
        XCTAssertEqual(store.count(status: "all"), 4)
        XCTAssertEqual(store.count(status: "running"), 2)
        store.showTag("ml")
        XCTAssertEqual(store.count(status: "all"), 2)
        XCTAssertEqual(store.count(status: "running"), 1)
        XCTAssertEqual(store.favoritesCount, 1)
    }

    func testKeyboardActions() async {
        let store = await makeStore(library)
        XCTAssertFalse(store.playSelected())              // nothing selected
        XCTAssertFalse(store.requestDeleteSelected())
        store.selectedId = "2"
        XCTAssertTrue(store.requestDeleteSelected())
        XCTAssertEqual(store.pendingConfirmation?.id, AppStore.PendingConfirmation.delete(store.papers["2"]!).id)

        let visible = store.filteredPapers()              // 1, 3, 2, 4
        store.selectedId = nil
        XCTAssertTrue(store.moveSelection(.right, in: visible, columns: 2))
        XCTAssertEqual(store.selectedId, "1")             // nothing selected → first
        store.moveSelection(.down, in: visible, columns: 2)
        XCTAssertEqual(store.selectedId, "2")
        store.moveSelection(.left, in: visible, columns: 2)
        XCTAssertEqual(store.selectedId, "3")
        XCTAssertFalse(store.moveSelection(.down, in: [], columns: 2))
    }

    func testPlaySelectedIgnoresPapersWithoutAnEpisode() async {
        let store = await makeStore([Fixtures.paper(id: "p", hasScript: false, hasAudio: false)])
        store.selectedId = "p"
        XCTAssertFalse(store.playSelected())
    }

    func testRerunOfAnEpisodeAsksFirst() async {
        let p = Fixtures.paper(id: "p")
        let store = await makeStore([p])
        store.requestRerun(p)
        XCTAssertEqual(store.pendingConfirmation?.id, AppStore.PendingConfirmation.rerun(p).id)
        XCTAssertEqual(store.papers["p"]?.state, "done")  // nothing started yet
    }

    func testConfirmingADeleteCarriesItOut() async {
        let p = Fixtures.paper(id: "p")
        let store = await makeStore([p])
        store.pendingConfirmation = .delete(p)
        store.confirmPending(.delete(p))
        XCTAssertNil(store.pendingConfirmation)
        await waitUntil { store.papers["p"] == nil }
    }

    func testCommitTitleEdit() async {
        let store = await makeStore([Fixtures.paper(id: "p", title: "Old")])
        XCTAssertEqual(store.commitTitleEdit("p", draft: "   "), "Old")       // empty reverts
        XCTAssertEqual(store.commitTitleEdit("p", draft: " New  name "), "New name")
        XCTAssertEqual(store.papers["p"]?.title, "New name")
        await waitUntil { await self.onDisk("p")?.title == "New name" }
    }

    func testSaveMetadataFromTheForm() async {
        let p = Fixtures.paper(id: "p")
        let store = await makeStore([p])
        var form = MetadataForm(p)
        form.authors = " Ada \n\n Grace "
        form.doi = " 10.1/y "
        store.saveMetadata("p", form)
        XCTAssertEqual(store.papers["p"]?.authors, ["Ada", "Grace"])
        XCTAssertEqual(store.papers["p"]?.doi, "10.1/y")
    }

    func testCheckConnectionsReportsWhatFailed() async {
        let store = await makeStore()
        // Storage server answers, LLM is down.
        MockLLM.install { request in
            if request.url?.host == "storage.mock" { return (200, Data("[]".utf8)) }
            return (500, Data())
        }
        let partial = await store.checkConnections(server: ServerConfig(apiBase: "http://storage.mock", token: ""),
                                                   llmBaseURL: "http://llm.mock", apiKey: "", model: "m")
        XCTAssertFalse(partial.ok)
        XCTAssertEqual(partial.message, "Could not reach: LLM.")

        MockLLM.install { request in
            request.url?.host == "storage.mock" ? (200, Data("[]".utf8)) : (200, MockLLM.modelsReply(["m"]))
        }
        let good = await store.checkConnections(server: ServerConfig(apiBase: "http://storage.mock", token: ""),
                                                llmBaseURL: "http://llm.mock", apiKey: "", model: "m")
        XCTAssertTrue(good.ok)
        XCTAssertEqual(good.message, "Both connections look good.")

        // Local library and no LLM: nothing to reach, nothing to fail.
        let none = await store.checkConnections(server: ServerConfig(apiBase: "", token: ""),
                                                llmBaseURL: "", apiKey: "", model: "")
        XCTAssertTrue(none.ok)
    }

    func testSettingsAreOnlyWrittenWhenChanged() async {
        let store = await makeStore()
        let before = store.prompts
        store.savePrompts(before)
        XCTAssertEqual(store.prompts, before)
        store.saveServerSettings(store.config)             // unchanged: no write, no change
        store.saveLLMSettings(store.llm)
    }

    // MARK: prompts, imports, log, toasts

    func testMindMapIsReadFromThePaperFolder() async throws {
        let store = await makeStore([Fixtures.paper(id: "m")])
        let none = await store.mindMap(for: "m")
        XCTAssertNil(none)
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply()))
        await storage.save(map, K.mindMap("m"))
        let loaded = await store.mindMap(for: "m")
        XCTAssertEqual(loaded, map)
        XCTAssertEqual(K.mindMap("m"), "papers/m/mindmap.json")
        XCTAssertTrue(store.drawingMindMaps.isEmpty)
    }

    func testResolvingWithNothingPendingIsHarmless() async {
        let store = await makeStore()
        store.resolveDuplicate(true)
        store.resolveCast([])
        store.resolveCast([], voiceAudio: false)
        store.cancelCast()
        XCTAssertNil(store.pendingCast)
        XCTAssertNil(store.pendingDuplicate)
    }

    func testPendingConfirmationIdsAreDistinct() async {
        let p = Fixtures.paper(id: "x")
        XCTAssertNotEqual(AppStore.PendingConfirmation.delete(p).id, AppStore.PendingConfirmation.rerun(p).id)
    }

    func testBeginImportCarriesDroppedFile() async {
        let store = await makeStore()
        let url = URL(fileURLWithPath: "/tmp/paper.pdf")
        store.beginImport(url)
        XCTAssertTrue(store.showUpload)
        XCTAssertEqual(store.pendingUploadURL, url)
        store.beginImport()
        XCTAssertNil(store.pendingUploadURL)
    }

    func testActiveRunsAndImportFocusCycle() async {
        let store = await makeStore(library)                // "2" running (2024-01), "3" queued (2024-02)
        XCTAssertEqual(store.activeRuns.map(\.id), ["2", "3"])
        XCTAssertEqual(store.activeRun?.id, "2")
        store.focusImport(1)
        XCTAssertEqual(store.activeRun?.id, "3")
        store.focusImport(1)
        XCTAssertEqual(store.activeRun?.id, "2")      // wraps around
        store.focusImport(-1)
        XCTAssertEqual(store.activeRun?.id, "3")
    }

    func testLogIsTaggedPerPaperAndCapped() async {
        let store = await makeStore()
        store.appendLog("for a", paper: "a")
        store.appendLog("global")
        store.appendLog("for b", paper: "b")
        XCTAssertEqual(store.logLines(for: "a").count, 1)
        XCTAssertTrue(store.logLines(for: "a")[0].hasSuffix("for a"))
        for i in 0..<2100 { store.appendLog("line \(i)", paper: "a") }
        XCTAssertEqual(store.logEntries.count, 2000)
    }

    func testToastAutoDismisses() async {
        let store = await makeStore()
        store.show("Hello")
        XCTAssertEqual(store.toast, "Hello")
        store.show("Second")                           // replaces, restarts the timer
        XCTAssertEqual(store.toast, "Second")
        await waitUntil(timeout: 6) { store.toast == nil }
    }
}
