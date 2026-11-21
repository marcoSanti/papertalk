// Tests of suggested papers: reading Semantic Scholar's replies, merging and de-duplicating,
// the daily schedule, the LLM's ranking, spotting a finished download, the window's wording,
// and the store's check, dismiss and fetch steps (Semantic Scholar and the LLM mocked).

import XCTest
@testable import Papertalk

@MainActor
final class SuggestionsTests: PapertalkTestCase {
    nonisolated(unsafe) private var storage: LocalStorage!
    nonisolated(unsafe) private var downloads: URL!

    override func setUp() {
        super.setUp()
        storage = LocalStorage(root: Fixtures.tempDir())
        downloads = Fixtures.tempDir()
    }

    private static func suggestion(_ title: String, doi: String? = nil, pdf: String? = nil,
                                   page: String? = "https://doi.org/x") -> Suggestion {
        Suggestion(id: Suggestions.key(title: title, doi: doi), title: title, authors: ["A. Author"], year: 2025,
                   abstract: nil, doi: doi, pageURL: page, pdfURL: pdf, source: .semanticScholar, reason: nil)
    }

    nonisolated private static let reply = """
    {"recommendedPapers": [
      {"paperId": "a", "title": "Sparse Attention at Scale", "authors": [{"name": "Ada L."}, {"name": "Bo K."}],
       "year": 2026, "abstract": "We study.", "externalIds": {"DOI": "10.1/SPARSE", "CorpusId": 7},
       "openAccessPdf": {"url": "https://example.org/s.pdf", "status": "GREEN"}, "url": "https://s2/a"},
      {"paperId": "b", "title": "Long Context Retrieval", "externalIds": {"ArXiv": "2610.11430", "CorpusId": 8},
       "openAccessPdf": {"url": "", "status": null}, "url": "https://s2/b"},
      {"paperId": "c", "title": "Closed Paper", "externalIds": {"CorpusId": 9},
       "openAccessPdf": {"url": "", "status": null}, "url": "https://s2/c"},
      {"paperId": "d", "title": "  "}
    ]}
    """

    private func makeStore(_ papers: [Paper], pending: [Suggestion] = []) async -> AppStore {
        for p in papers { await storage.save(p, K.paper(p.id)) }
        if !pending.isEmpty { await storage.save(SuggestionLog(pending: pending), K.suggestions) }
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == papers.count && store.suggestionLog.pending.count == pending.count }
        store.downloadsFolder = downloads
        store.downloadsPollInterval = 0.05
        return store
    }

    /// Answers Semantic Scholar with `reply` and the LLM with `rank`, counting Semantic Scholar's calls.
    private func mockServices(reply: String = SuggestionsTests.reply, status: Int = 200, rank: String? = nil,
                              seen: @escaping ([String]) -> Void = { _ in }) {
        MockLLM.install { request in
            if request.url?.host == "api.semanticscholar.org" {
                let body = MockLLM.bodyData(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] }
                seen(body?["positivePaperIds"] ?? [])
                return (status, Data(reply.utf8))
            }
            return (200, MockLLM.chatReply(rank ?? "nothing useful"))
        }
    }

    // MARK: Pure rules

    func testSemanticScholarReplyBecomesSuggestionsWithTheBestPDFAndPage() throws {
        let found = try XCTUnwrap(Suggestions.parseSemanticScholar(Data(Self.reply.utf8)))
        XCTAssertEqual(found.map(\.title), ["Sparse Attention at Scale", "Long Context Retrieval", "Closed Paper"])
        XCTAssertEqual(found[0].id, "doi:10.1/sparse")
        XCTAssertEqual(found[0].authors, ["Ada L.", "Bo K."])
        XCTAssertEqual(found[0].pdfURL, "https://example.org/s.pdf")
        XCTAssertEqual(found[0].pageURL, "https://doi.org/10.1/SPARSE")
        // An empty open-access link isn't a PDF, but an arXiv paper always has one.
        XCTAssertEqual(found[1].pdfURL, "https://arxiv.org/pdf/2610.11430")
        XCTAssertEqual(found[1].pageURL, "https://s2/b")
        XCTAssertNil(found[2].pdfURL)
        XCTAssertEqual(found[2].id, "title:closed paper")
        XCTAssertNil(Suggestions.parseSemanticScholar(Data("{\"error\": \"x\"}".utf8)))
    }

    func testSeedsAreTheNewestPapersWithADOIAndNeverDecks() {
        var deck = Fixtures.paper(id: "deck", doi: "10.9/deck"); deck.kind = Paper.slidesKind
        let papers = [Fixtures.paper(id: "old", createdIso: "2024-01-01T00:00:00Z", doi: "10.1/old"),
                      Fixtures.paper(id: "new", createdIso: "2026-01-01T00:00:00Z", doi: " 10.1/new "),
                      Fixtures.paper(id: "none", doi: ""), deck]
        XCTAssertEqual(Suggestions.seeds(papers), ["DOI:10.1/new", "DOI:10.1/old"])
        let many = (0..<150).map { Fixtures.paper(id: "\($0)", doi: "10.1/\($0)") }
        XCTAssertEqual(Suggestions.seeds(many).count, Suggestions.maxSeeds)
    }

    func testMergeSkipsWhatIsInTheLibraryPendingHandledOrRepeated() {
        let library = [Fixtures.paper(title: "Owned Paper", doi: "10.1/OWNED"), Fixtures.paper(title: "Known Title!", doi: "")]
        var log = SuggestionLog()
        log.pending = [Self.suggestion("Waiting")]
        log.handled = [Suggestions.key(title: "Dismissed", doi: nil)]
        let found = [Self.suggestion("Owned under another name", doi: "10.1/owned"), Self.suggestion("known title"),
                     Self.suggestion("Waiting"), Self.suggestion("Dismissed"), Self.suggestion("Fresh", doi: "10.2/f"),
                     Self.suggestion("Fresh"), Self.suggestion("")]
        let (merged, added) = Suggestions.merge(found, into: log, library: library)
        XCTAssertEqual(added.map(\.title), ["Fresh"])
        XCTAssertEqual(merged.pending.map(\.title), ["Waiting", "Fresh"])
    }

    func testCheckIsDueOncePerCalendarDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        let morning = iso.date(from: "2026-11-20T08:00:00Z")!
        XCTAssertTrue(Suggestions.isDue(lastCheckIso: nil, now: morning, calendar: cal))
        XCTAssertFalse(Suggestions.isDue(lastCheckIso: "2026-11-20T07:00:00Z", now: morning, calendar: cal))
        XCTAssertTrue(Suggestions.isDue(lastCheckIso: "2026-11-19T23:00:00Z", now: morning, calendar: cal))
        XCTAssertTrue(Suggestions.isDue(lastCheckIso: "garbage", now: morning, calendar: cal))
    }

    func testRankingReordersAndKeepsTheUnrankedAfter() throws {
        let c = ["A", "B", "C", "D"].map { Self.suggestion($0) }
        let raw = "Sure!\n```json\n{\"ranked\": [{\"n\": 3, \"why\": \" Same topic. \"}, {\"n\": 1}, {\"n\": 3}, {\"n\": 9}]}\n```"
        let ranked = try XCTUnwrap(Suggestions.applyRanking(raw, to: c))
        XCTAssertEqual(ranked.map(\.title), ["C", "A", "B", "D"])
        XCTAssertEqual(ranked[0].reason, "Same topic.")
        XCTAssertNil(ranked[1].reason)
        XCTAssertNil(Suggestions.applyRanking("no json here", to: c))
        let input = Suggestions.rankingInput(library: ["Mine"], candidates: c)
        XCTAssertTrue(input.contains("LIBRARY:\n- Mine"))
        XCTAssertTrue(input.contains("3. C (2025)"))
    }

    func testTitleMatchNeedsMostOfTheTitlesLongerWords() {
        XCTAssertTrue(Suggestions.titleMatches("Sparse Attention at Scale", text: "SPARSE ATTENTION AT SCALE\nAda L."))
        XCTAssertFalse(Suggestions.titleMatches("Sparse Attention at Scale", text: "Invoice for October"))
        XCTAssertTrue(Suggestions.titleMatches("A to B", text: "anything"))
    }

    func testAFinishedPDFIsNewNonEmptyStillAndHasNoPartialCopy() {
        let before: Set<String> = ["old.pdf"]
        // Firefox: an empty placeholder beside the .part file.
        XCTAssertNil(Suggestions.finishedPDF(now: ["old.pdf": 9, "p.pdf": 0, "p.pdf.part": 50],
                                             previous: ["old.pdf": 9, "p.pdf": 0, "p.pdf.part": 10], before: before))
        // Still growing, or seen for the first time.
        XCTAssertNil(Suggestions.finishedPDF(now: ["p.pdf": 80], previous: ["p.pdf": 50], before: before))
        XCTAssertNil(Suggestions.finishedPDF(now: ["p.pdf": 80], previous: [:], before: before))
        // Chrome's in-progress name isn't a PDF; the old file never counts.
        XCTAssertNil(Suggestions.finishedPDF(now: ["old.pdf": 9, "p.pdf.crdownload": 5], previous: ["old.pdf": 9, "p.pdf.crdownload": 5], before: before))
        XCTAssertEqual(Suggestions.finishedPDF(now: ["old.pdf": 9, "P.PDF": 80], previous: ["P.PDF": 80], before: before), "P.PDF")
    }

    func testDownloadedFileNameDropsCharactersFileSystemsRefuse() {
        XCTAssertEqual(Suggestions.fileName(for: Self.suggestion("A/B: C?")), "A B  C.pdf")
    }

    func testLastImportChoiceRoundTripsAndFallsBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "suggestions-\(UUID().uuidString)"))
        XCTAssertEqual(ImportChoice.load(defaults).resolvedDepth, .inDepth)
        ImportChoice(depth: Depth.summary.rawValue, depthNote: "", targetMinutes: 20, scriptLanguage: "it").save(defaults)
        let back = ImportChoice.load(defaults)
        XCTAssertEqual(back.resolvedDepth, .summary)
        XCTAssertEqual(back.targetMinutes, 20)
        XCTAssertEqual(ImportChoice(depth: "gone", scriptLanguage: "xx").resolvedDepth, .inDepth)
        XCTAssertNil(ImportChoice(scriptLanguage: "xx").resolvedLanguage)
    }

    // MARK: Wording

    func testWindowWording() {
        var s = Self.suggestion("T", pdf: "https://x/p.pdf")
        s.authors = ["A", "B", "C", "D"]
        XCTAssertEqual(SuggestionsPresentation.details(s), "A, B, C et al. · 2025")
        s.authors = []; s.year = nil; s.source = .scholarAlert
        XCTAssertEqual(SuggestionsPresentation.details(s), "")
        XCTAssertEqual(SuggestionsPresentation.source(.scholarAlert), "Google Scholar alert")
        XCTAssertEqual(SuggestionsPresentation.source(.semanticScholar), "Semantic Scholar")
        XCTAssertEqual(SuggestionsPresentation.sourceIcon(.scholarAlert), "envelope")
        XCTAssertEqual(SuggestionsPresentation.sourceIcon(.semanticScholar), "magnifyingglass")
        XCTAssertNotEqual(SuggestionsPresentation.sourceHelp(.scholarAlert), SuggestionsPresentation.sourceHelp(.semanticScholar))
        XCTAssertEqual(SuggestionsPresentation.setUpAlertsButton, "Set Up Scholar Alerts…")
        XCTAssertTrue(SuggestionsPresentation.setUpAlertsHelp.hasPrefix("Opens Settings → Suggested Papers"))
        XCTAssertEqual(SuggestionsPresentation.availability(s), "Free PDF")
        XCTAssertEqual(SuggestionsPresentation.availabilityIcon(s), "arrow.down.doc")
        s.pdfURL = nil
        XCTAssertEqual(SuggestionsPresentation.availability(s), "Download in browser")
        XCTAssertEqual(SuggestionsPresentation.availabilityIcon(s), "safari")
        XCTAssertTrue(SuggestionsPresentation.availabilityHelp(s).contains("Downloads"))
        XCTAssertTrue(SuggestionsPresentation.isFree(Self.suggestion("x", pdf: "https://x/p.pdf")))
        XCTAssertFalse(SuggestionsPresentation.isFree(s))
        XCTAssertEqual(SuggestionsPresentation.found(0), "No new papers this time.")
        XCTAssertEqual(SuggestionsPresentation.found(1), "1 new paper like yours.")
        XCTAssertEqual(SuggestionsPresentation.found(4), "4 new papers like yours.")
        XCTAssertEqual(SuggestionsPresentation.foundToast(1), "1 new suggested paper. See it under Suggested Papers in the sidebar.")
        XCTAssertTrue(SuggestionsPresentation.foundToast(2).hasPrefix("2 new suggested papers."))
        XCTAssertEqual(SuggestionsPresentation.lastChecked(nil), "Not checked yet")
        XCTAssertTrue(SuggestionsPresentation.lastChecked("2026-11-20T08:00:00Z").hasPrefix("Last checked "))
        XCTAssertEqual(SuggestionsPresentation.checkButton(checking: true), "Checking…")
        XCTAssertEqual(SuggestionsPresentation.checkButton(checking: false), "Check Now")
        XCTAssertFalse(SuggestionsPresentation.canCheck(checking: true))
        XCTAssertTrue(SuggestionsPresentation.canCheck(checking: false))
        XCTAssertNotEqual(SuggestionsPresentation.emptyMessage(enabled: true), SuggestionsPresentation.emptyMessage(enabled: false))
        XCTAssertEqual(SuggestionsPresentation.importDepths(current: .summary), [.inDepth, .summary, .direct])
        XCTAssertEqual(SuggestionsPresentation.importDepths(current: .custom), [.inDepth, .summary, .direct, .custom])
        XCTAssertTrue(SuggestionsPresentation.mismatch(file: "f.pdf", title: "T").contains("“f.pdf”"))
        XCTAssertTrue(SuggestionsPresentation.checkFailed("boom").hasSuffix("boom"))
    }

    func testTabsSplitBySource() {
        var alert = Self.suggestion("A", pdf: nil)
        alert.source = .scholarAlert
        let all = [Self.suggestion("S1", pdf: nil), alert, Self.suggestion("S2", pdf: nil)]
        XCTAssertEqual(SuggestionsPresentation.tabs, [.semanticScholar, .scholarAlert])
        XCTAssertEqual(SuggestionsPresentation.pending(all, in: .semanticScholar).map(\.title), ["S1", "S2"])
        XCTAssertEqual(SuggestionsPresentation.pending(all, in: .scholarAlert).map(\.title), ["A"])
        XCTAssertEqual(SuggestionsPresentation.tabLabel(.semanticScholar, count: 2), "Semantic Scholar (2)")
        XCTAssertEqual(SuggestionsPresentation.tabLabel(.scholarAlert, count: 0), "Google Scholar alerts (0)")
        XCTAssertTrue(SuggestionsPresentation.showsAlertSetup(tab: .scholarAlert, ready: false))
        XCTAssertFalse(SuggestionsPresentation.showsAlertSetup(tab: .scholarAlert, ready: true))
        XCTAssertFalse(SuggestionsPresentation.showsAlertSetup(tab: .semanticScholar, ready: false))
    }

    func testFetchPanelWording() {
        var f = PaperFetch(current: Self.suggestion("Paper"), queue: [], step: .downloading, total: 3, position: 2)
        XCTAssertEqual(SuggestionsPresentation.position(f), "Paper 2 of 3")
        XCTAssertEqual(SuggestionsPresentation.heading(f), "Getting “Paper”")
        XCTAssertEqual(SuggestionsPresentation.status(f), "Downloading the free PDF…")
        XCTAssertFalse(SuggestionsPresentation.showsBrowserSteps(f))
        f.step = .waiting
        XCTAssertEqual(SuggestionsPresentation.status(f), "Waiting for a new PDF in Downloads…")
        XCTAssertTrue(SuggestionsPresentation.showsBrowserSteps(f))
        XCTAssertEqual(SuggestionsPresentation.browserSteps.count, 3)
        XCTAssertTrue(SuggestionsPresentation.canOpenPage(f.current))
        f.current.pageURL = nil
        XCTAssertFalse(SuggestionsPresentation.canOpenPage(f.current))
        f.step = .importing("p.pdf")
        XCTAssertEqual(SuggestionsPresentation.status(f), "Found “p.pdf”. Importing…")
    }

    func testRowStateFollowsTheImportQueue() {
        let a = Self.suggestion("A"), b = Self.suggestion("B"), c = Self.suggestion("C")
        let f = PaperFetch(current: a, queue: [b], step: .waiting, total: 2, position: 1)
        XCTAssertEqual(SuggestionsPresentation.rowState(a.id, fetch: f), .fetching)
        XCTAssertEqual(SuggestionsPresentation.rowState(b.id, fetch: f), .queued)
        XCTAssertEqual(SuggestionsPresentation.rowState(c.id, fetch: f), .idle)
        XCTAssertEqual(SuggestionsPresentation.rowState(a.id, fetch: nil), .idle)
        XCTAssertEqual(SuggestionsPresentation.rowStatus(.queued), "Queued")
        XCTAssertEqual(SuggestionsPresentation.rowStatus(.fetching), "Importing…")
        XCTAssertNil(SuggestionsPresentation.rowStatus(.idle))
        XCTAssertTrue(SuggestionsPresentation.canAct(.idle))
        XCTAssertFalse(SuggestionsPresentation.canAct(.queued))
    }

    func testDetailsPanelWording() {
        var s = Self.suggestion("T", doi: "10.1/x")
        s.authors = ["A", "B", "C", "D"]
        XCTAssertEqual(SuggestionsPresentation.authors(s), "A, B, C, D")
        XCTAssertEqual(SuggestionsPresentation.doiLine(s), "DOI 10.1/x")
        XCTAssertTrue(SuggestionsPresentation.abstract(s).hasPrefix("Semantic Scholar has no abstract"))
        s.abstract = "  We study.\n"
        XCTAssertEqual(SuggestionsPresentation.abstract(s), "We study.")
        s.doi = nil
        XCTAssertNil(SuggestionsPresentation.doiLine(s))
    }

    // MARK: Store

    func testSuggestedIsASidebarSectionWithoutPapersAndItsOwnSelection() async {
        let s = Self.suggestion("Shown")
        let store = await makeStore([Fixtures.paper(id: "p")], pending: [s])
        store.selectedId = "p"
        store.selectSidebar(.suggested)
        XCTAssertTrue(store.showsSuggestions)
        XCTAssertEqual(store.sidebarSelection, .suggested)
        XCTAssertEqual(store.sidebarCount(.suggested), 1)
        XCTAssertTrue(store.filteredPapers().isEmpty)
        XCTAssertNil(store.selectedId)
        XCTAssertFalse(store.sidebarItems.contains(.suggested))
        XCTAssertEqual(LibraryPresentation.title(view: .suggested, tag: nil, author: nil), "Suggested Papers")
        XCTAssertEqual(LibraryPresentation.sidebarTitle(.suggested), "Suggested Papers")
        store.selectedSuggestionId = s.id
        XCTAssertEqual(store.selectedSuggestion, s)
        store.dismissSuggestions([s.id])
        XCTAssertNil(store.selectedSuggestion)
        store.selectSidebar(.all)
        XCTAssertFalse(store.showsSuggestions)
    }

    func testImportingMoreWhileOneRunsQueuesThemAndQueuedOnesCantBeDismissed() async {
        let a = Self.suggestion("Closed A"), b = Self.suggestion("Closed B"), c = Self.suggestion("Closed C")
        let store = await makeStore([], pending: [a, b, c])
        store.importSuggestions([a.id])
        await waitUntil { store.paperFetch?.step == .waiting }
        store.importSuggestions([b.id, a.id])
        XCTAssertEqual(store.paperFetch?.queue.map(\.id), [b.id])
        XCTAssertEqual(store.paperFetch?.total, 2)
        store.dismissSuggestions([a.id, b.id, c.id])
        XCTAssertEqual(store.suggestionLog.pending.map(\.id), [a.id, b.id])
        store.stopFetch()
    }

    func testCheckAddsNewPapersRanksThemAndSavesTheLog() async throws {
        let store = await makeStore([Fixtures.paper(id: "p", title: "Dense Attention", doi: "10.1/dense")])
        store.llm.baseUrl = "http://mock.local/v1"
        var sent: [String] = []
        mockServices(rank: "{\"ranked\": [{\"n\": 2, \"why\": \"Long context, like your attention paper.\"}]}") { sent = $0 }
        let now = ISO8601DateFormatter().date(from: "2026-11-20T08:00:00Z")!

        await store.checkSuggestions(now: now)

        XCTAssertEqual(sent, ["DOI:10.1/dense"])
        XCTAssertEqual(store.suggestionLog.pending.map(\.title), ["Long Context Retrieval", "Sparse Attention at Scale", "Closed Paper"])
        XCTAssertEqual(store.suggestionLog.pending[0].reason, "Long context, like your attention paper.")
        XCTAssertEqual(store.suggestionLog.lastCheckIso, "2026-11-20T08:00:00Z")
        XCTAssertEqual(store.suggestionsStatus, "3 new papers like yours.")
        await waitUntil { await self.storage.exists(SuggestionLog.self, K.suggestions)?.pending.count == 3 }

        // A second check the same way adds nothing.
        await store.checkSuggestions(now: now)
        XCTAssertEqual(store.suggestionLog.pending.count, 3)
        XCTAssertEqual(store.suggestionsStatus, "No new papers this time.")

        // A new store reads the log back.
        let again = AppStore(storage: storage)
        await waitUntil { again.suggestionLog.pending.count == 3 }
    }

    func testFailuresAndAMissingDOILeaveTheListAsItWas() async {
        let store = await makeStore([Fixtures.paper(id: "p", doi: "")])
        await store.checkSuggestions()
        XCTAssertEqual(store.suggestionsStatus, SuggestionsPresentation.noSeeds)

        storage = LocalStorage(root: Fixtures.tempDir())
        let withDOI = await makeStore([Fixtures.paper(id: "q", doi: "10.1/q")])
        mockServices(status: 429)
        await withDOI.checkSuggestions()
        XCTAssertEqual(withDOI.suggestionsStatus, "Couldn't check for suggested papers: Semantic Scholar answered HTTP 429.")
        XCTAssertNil(withDOI.suggestionLog.lastCheckIso)
        XCTAssertTrue(withDOI.suggestionLog.pending.isEmpty)
    }

    /// A check that lands before the startup scan read the log still keeps what was dismissed.
    func testACheckMergesIntoTheLogOnDiskNotAnUnloadedOne() async {
        await storage.save(Fixtures.paper(id: "p", doi: "10.1/p"), K.paper("p"))
        let closed = Suggestions.key(title: "Closed Paper", doi: nil)
        await storage.save(SuggestionLog(pending: [], handled: [closed]), K.suggestions)
        mockServices()
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == 1 && store.suggestionLog.handled == [closed] }
        store.suggestionLog = SuggestionLog()   // as if the scan hadn't read it yet
        await store.checkSuggestions()
        XCTAssertFalse(store.suggestionLog.pending.contains { $0.id == closed })
        XCTAssertEqual(store.suggestionLog.handled, [closed])
    }

    func testWithoutAnLLMOrAReadableRankingTheSourceOrderStays() async {
        let store = await makeStore([Fixtures.paper(id: "p", doi: "10.1/p")])
        store.llm.baseUrl = "http://mock.local/v1"
        mockServices(rank: "I can't rank these.")
        await store.checkSuggestions()
        XCTAssertEqual(store.suggestionLog.pending.map(\.title), ["Sparse Attention at Scale", "Long Context Retrieval", "Closed Paper"])
    }

    func testTheDailyCheckRunsOnlyWhenOnAndDue() async {
        let store = await makeStore([Fixtures.paper(id: "p", doi: "10.1/p")])
        let wasOn = store.suggestionsEnabled
        defer { store.suggestionsEnabled = wasOn }
        var calls = 0
        mockServices { _ in calls += 1 }
        store.showOnboarding = false
        store.suggestionsEnabled = false
        await store.checkSuggestionsIfDue()
        XCTAssertEqual(calls, 0)
        store.suggestionsEnabled = true
        await store.checkSuggestionsIfDue()
        await store.checkSuggestionsIfDue()
        XCTAssertEqual(calls, 1)
    }

    func testTheDepthMenuChangesOnlyTheDepthOfTheImportChoice() async {
        let store = await makeStore([])
        let saved = store.importChoice
        defer { store.importChoice = saved }
        store.importChoice = ImportChoice(depth: Depth.inDepth.rawValue, depthNote: "", targetMinutes: 20, scriptLanguage: "it")
        XCTAssertEqual(store.suggestionDepth, .inDepth)
        store.suggestionDepth = .summary
        XCTAssertEqual(store.importChoice, ImportChoice(depth: "summary", depthNote: "", targetMinutes: 20, scriptLanguage: "it"))
        XCTAssertEqual(ImportChoice.load().resolvedDepth, .summary)
        store.mailPassword = { "" }
        XCTAssertFalse(store.alertsReady)
    }

    func testDismissedSuggestionsNeverComeBack() async {
        let store = await makeStore([Fixtures.paper(id: "p", doi: "10.1/p")])
        mockServices()
        await store.checkSuggestions()
        let closed = Suggestions.key(title: "Closed Paper", doi: nil)
        store.dismissSuggestions([closed])
        XCTAssertFalse(store.suggestionLog.pending.contains { $0.id == closed })
        XCTAssertEqual(store.suggestionLog.handled, [closed])
        store.suggestionLog.lastCheckIso = nil
        await store.checkSuggestions()
        XCTAssertFalse(store.suggestionLog.pending.contains { $0.id == closed })
    }

    func testAPaperWithoutAFreePDFWaitsForDownloadsAndCanBeSkippedOrStopped() async throws {
        let a = Self.suggestion("Closed A"), b = Self.suggestion("Closed B")
        let store = await makeStore([], pending: [a, b])
        // Already in Downloads before the wait: never taken for the paper.
        try Data("%PDF-1.4 old".utf8).write(to: downloads.appendingPathComponent("old.pdf"))

        store.importSuggestions([a.id, b.id])
        await waitUntil { store.paperFetch?.step == .waiting }
        XCTAssertEqual(store.paperFetch?.current.id, a.id)
        XCTAssertEqual(store.paperFetch?.total, 2)

        store.skipFetch()
        await waitUntil { store.paperFetch?.current.id == b.id && store.paperFetch?.step == .waiting }
        XCTAssertEqual(store.paperFetch?.position, 2)
        store.stopFetch()
        XCTAssertNil(store.paperFetch)
        // Neither was imported, so both still wait in the list.
        XCTAssertEqual(store.suggestionLog.pending.map(\.id), [a.id, b.id])
    }

    func testEachImportKeepsTheLibraryItWasFiledIn() async {
        let a = Self.suggestion("Closed A"), b = Self.suggestion("Closed B"), c = Self.suggestion("Closed C")
        let store = await makeStore([], pending: [a, b, c])
        store.importSuggestions([a.id], library: "lib-1")
        await waitUntil { store.paperFetch?.step == .waiting }
        store.importSuggestions([b.id])                       // queued, no library
        store.importSuggestions([c.id], library: "lib-2")     // queued, another library
        XCTAssertEqual(store.paperFetch?.libraries, [a.id: "lib-1", c.id: "lib-2"])
        store.stopFetch()
        XCTAssertFalse(SuggestionsPresentation.asksLibrary([]))
        XCTAssertTrue(SuggestionsPresentation.asksLibrary([Library(id: "lib-1", name: "ML", icon: "books.vertical", connectsAcross: false)]))
    }

    func testAFreePDFThatIsntOneFallsBackToTheBrowser() async {
        let s = Self.suggestion("Open", pdf: "https://example.org/landing")
        let store = await makeStore([], pending: [s])
        MockLLM.install { _ in (200, Data("<html>sign in</html>".utf8)) }
        store.importSuggestions([s.id])
        await waitUntil { store.paperFetch?.step == .waiting }
        store.stopFetch()
    }
}
