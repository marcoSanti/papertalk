import XCTest
@testable import Papertalk

/// The presentation layer: every decision the views used to make inline.
/// Pure functions and value types, so these need no store, disk or network.
final class LibraryPresentationTests: PapertalkTestCase {
    func testTitles() {
        XCTAssertEqual(LibraryPresentation.title(view: .all, tag: nil, author: nil), "All Papers")
        XCTAssertEqual(LibraryPresentation.title(view: .fav, tag: nil, author: nil), "Favorites")
        XCTAssertEqual(LibraryPresentation.title(view: .authors, tag: nil, author: nil), "Authors")
        XCTAssertEqual(LibraryPresentation.title(view: .tag, tag: "nlp", author: nil), "#nlp")
        XCTAssertEqual(LibraryPresentation.title(view: .tag, tag: nil, author: nil), "Tag")
        XCTAssertEqual(LibraryPresentation.title(view: .author, tag: nil, author: "Ada Lovelace"), "Ada Lovelace")
    }

    func testEmptyStateText() {
        XCTAssertEqual(LibraryPresentation.emptyStateText(.emptyLibrary).title, "Your library is empty")
        XCTAssertTrue(LibraryPresentation.emptyStateText(.emptyLibrary).message.hasSuffix("right on \(Device.this)."))
        XCTAssertEqual(LibraryPresentation.emptyStateText(.noSearchResults(" attention ")).title, "No results for “attention”")
        XCTAssertEqual(LibraryPresentation.emptyStateText(.filteredOut).message, "No papers match the current filters.")
    }

    func testSettingsSheetCopy() {
        XCTAssertEqual(SettingsSheetPresentation.title(isSetup: true), "Welcome to Papertalk")
        XCTAssertEqual(SettingsSheetPresentation.title(isSetup: false), "Settings")
        XCTAssertEqual(SettingsSheetPresentation.saveTitle(isSetup: true), "Finish setup")
        XCTAssertEqual(SettingsSheetPresentation.saveTitle(isSetup: false), "Save")
        XCTAssertTrue(SettingsSheetPresentation.intro.contains(Device.this))
        XCTAssertTrue(SettingsSheetPresentation.serverHelp.contains(Device.this))
    }

    func testImportFormFileLabels() {
        var form = ImportForm()
        XCTAssertEqual(form.chooseButtonTitle, "Choose PDF…")
        XCTAssertEqual(form.fileLabel, "No file chosen")
        form.setFile(name: "a.pdf", data: Data([1]))
        XCTAssertEqual(form.chooseButtonTitle, "Change…")
        XCTAssertEqual(form.fileLabel, "a.pdf")
    }

    func testConfirmationTextCombined() {
        let text = ConfirmationText.duplicate(of: Fixtures.paper(title: "T"))
        XCTAssertEqual(text.combined, "Already in library\n“T” already exists with the same title or DOI. Import it anyway?")
    }

    func testImportSheetCopyNamesThisMachine() {
        XCTAssertEqual(ImportForm.heading, "New episode")
        XCTAssertTrue(ImportForm.subheading.hasSuffix("converted on \(Device.this)."))
    }

    func testSidebarTitles() {
        XCTAssertEqual(LibraryPresentation.sidebarTitle(.all), "All Papers")
        XCTAssertEqual(LibraryPresentation.sidebarTitle(.favorites), "Favorites")
        XCTAssertEqual(LibraryPresentation.sidebarTitle(.authors), "Authors")
        XCTAssertEqual(LibraryPresentation.sidebarTitle(.tag("nlp")), "nlp")
    }

    func testCountsAndBadges() {
        XCTAssertEqual(LibraryPresentation.paperCount(1), "1 paper")
        XCTAssertEqual(LibraryPresentation.paperCount(0), "0 papers")
        XCTAssertEqual(LibraryPresentation.authorCount(3), "3 authors")
        XCTAssertNil(LibraryPresentation.badge(0))
        XCTAssertEqual(LibraryPresentation.badge(4), "4")
        XCTAssertEqual(LibraryPresentation.authorsSubtitle(0), "")
        XCTAssertEqual(LibraryPresentation.authorsSubtitle(1), "1 author")
    }

    func testStorageLocation() {
        XCTAssertEqual(LibraryPresentation.storageLocation(isStandalone: true).title, "On \(Device.this)")
        XCTAssertEqual(LibraryPresentation.storageLocation(isStandalone: false).icon, "server.rack")
    }

    func testStatusFiltersCoverEveryState() {
        XCTAssertEqual(LibraryPresentation.statusFilters.map(\.value), ["all", "running", "done", "error"])
    }

    func testEmptyStates() {
        XCTAssertEqual(LibraryPresentation.emptyState(libraryIsEmpty: true, search: "x"), .emptyLibrary)
        XCTAssertEqual(LibraryPresentation.emptyState(libraryIsEmpty: false, search: " q "), .noSearchResults(" q "))
        XCTAssertEqual(LibraryPresentation.emptyState(libraryIsEmpty: false, search: "  "), .filteredOut)
    }

    func testGridColumnsMatchTheAdaptiveGrid() {
        XCTAssertEqual(LibraryPresentation.gridColumns(width: 0), 1)
        XCTAssertEqual(LibraryPresentation.gridColumns(width: 194), 1)    // 150 + 2×22 padding
        XCTAssertEqual(LibraryPresentation.gridColumns(width: 366), 2)    // 2×150 + 22 + 44
        XCTAssertEqual(LibraryPresentation.gridColumns(width: 900), 5)
    }

    func testArrowKeyMovement() {
        let next = LibraryPresentation.nextIndex
        XCTAssertEqual(next(nil, .down, 4, 10), 0)            // nothing selected → first
        XCTAssertEqual(next(5, .left, 4, 10), 4)
        XCTAssertEqual(next(5, .right, 4, 10), 6)
        XCTAssertEqual(next(5, .up, 4, 10), 1)
        XCTAssertEqual(next(5, .down, 4, 10), 9)
        XCTAssertEqual(next(1, .up, 4, 10), 0)                // clamped at the top
        XCTAssertEqual(next(8, .down, 4, 10), 9)              // clamped at the end
        XCTAssertEqual(next(3, .down, 0, 10), 4)              // zero columns behaves like one
        XCTAssertNil(next(0, .down, 4, 0))                    // empty library
    }
}

final class WindowPresentationTests: PapertalkTestCase {
    func testConfirmationWording() {
        let p = Fixtures.paper(title: "Graphs")
        let delete = ConfirmationText(.delete(p))
        XCTAssertEqual(delete.title, "Delete “Graphs”?")
        XCTAssertEqual(delete.confirmLabel, "Delete paper")
        XCTAssertTrue(delete.message.contains("can’t be undone"))
        let rerun = ConfirmationText(.rerun(p))
        XCTAssertEqual(rerun.title, "Rerun “Graphs”?")
        XCTAssertEqual(rerun.confirmLabel, "Rerun episode")
        let dup = ConfirmationText.duplicate(of: p)
        XCTAssertEqual(dup.title, "Already in library")
        XCTAssertTrue(dup.message.contains("“Graphs”"))
    }

    func testSortLabels() {
        XCTAssertEqual(SortOption.allCases.map(\.label), ["Newest first", "Oldest first", "Title", "Recently converted"])
    }

    func testInspectorResizeIsClamped() {
        XCTAssertEqual(InspectorLayout.width(startingAt: 340, dragged: -60), 400)   // drag left: wider
        XCTAssertEqual(InspectorLayout.width(startingAt: 340, dragged: 500), 300)   // min
        XCTAssertEqual(InspectorLayout.width(startingAt: 340, dragged: -999), 520)  // max
    }

    func testFirstPDFInADrop() {
        let urls = [URL(fileURLWithPath: "/a/notes.txt"), URL(fileURLWithPath: "/a/Paper.PDF"), URL(fileURLWithPath: "/b.pdf")]
        XCTAssertEqual(ImportPresentation.firstPDF(in: urls)?.lastPathComponent, "Paper.PDF")
        XCTAssertNil(ImportPresentation.firstPDF(in: [URL(fileURLWithPath: "/x.png")]))
    }
}

final class AuthorsPresentationTests: PapertalkTestCase {
    private let byAuthor: [String: [Paper]] = [
        "Ada Lovelace": [Fixtures.paper(id: "1")],
        "Alan Turing": [Fixtures.paper(id: "2"), Fixtures.paper(id: "3")],
        "Grace Hopper": [Fixtures.paper(id: "4")],
        "Émile Zola": [Fixtures.paper(id: "5")],
        "Plato": [Fixtures.paper(id: "6")],
    ]

    func testSectionsAreGroupedBySurname() {
        let sections = AuthorsPresentation.sections(byAuthor, search: "")
        XCTAssertEqual(sections.map(\.letter), ["H", "L", "P", "T", "Z"])
        XCTAssertEqual(sections.first { $0.letter == "L" }?.entries.map(\.name), ["Ada Lovelace"])
        XCTAssertEqual(sections.first { $0.letter == "T" }?.entries.first?.papers.count, 2)
    }

    func testSearchFiltersAuthorsButTagSearchDoesNot() {
        XCTAssertEqual(AuthorsPresentation.sections(byAuthor, search: "turing").flatMap { $0.entries.map(\.name) }, ["Alan Turing"])
        XCTAssertEqual(AuthorsPresentation.sections(byAuthor, search: "#nlp").flatMap(\.entries).count, 5)
        XCTAssertTrue(AuthorsPresentation.sections(byAuthor, search: "nobody").isEmpty)
    }

    func testLetterIndexNeedsAFewSections() {
        XCTAssertFalse(AuthorsPresentation.showsLetterIndex(sectionCount: 4))
        XCTAssertTrue(AuthorsPresentation.showsLetterIndex(sectionCount: 5))
    }

    func testCoauthorsRankedBySharedPapersThenName() {
        let papers = [
            Fixtures.paper(authors: ["Ada", "Bob", "Cy"]),
            Fixtures.paper(authors: ["Ada", "Cy", "Cy "]),     // whitespace variant counts once
            Fixtures.paper(authors: ["Ada", "Al"]),
        ]
        let co = AuthorsPresentation.coauthors(of: "Ada", in: papers)
        XCTAssertEqual(co.map(\.name), ["Cy", "Al", "Bob"])
        XCTAssertEqual(co.map(\.shared), [2, 1, 1])
    }

    func testSummaryAndCoverStack() {
        XCTAssertEqual(AuthorsPresentation.summary(papers: 1, coauthors: 0), "1 paper")
        XCTAssertEqual(AuthorsPresentation.summary(papers: 3, coauthors: 1), "3 papers · 1 co-author")
        let stack = AuthorsPresentation.coverStack((0..<5).map { Fixtures.paper(id: "\($0)") })
        XCTAssertEqual(stack.shown.map(\.id), ["0", "1", "2"])
        XCTAssertEqual(stack.more, 2)
        XCTAssertEqual(AuthorsPresentation.coverStack([]).more, 0)
    }

    func testInitials() {
        XCTAssertEqual(AuthorName.initials("Ada Lovelace"), "AL")
        XCTAssertEqual(AuthorName.initials("ada king lovelace"), "AL")
        XCTAssertEqual(AuthorName.initials("Plato"), "P")
        XCTAssertEqual(AuthorName.initials(""), "?")
    }
}

final class PaperPresentationTests: PapertalkTestCase {
    func testAuthorLines() {
        XCTAssertEqual(PaperPresentation.authorLine(["A", "B"]), "A, B")
        XCTAssertEqual(PaperPresentation.authorLine(["A", "B", "C", "D"]), "A, B, C et al.")
        XCTAssertEqual(PaperPresentation.cardSubtitle(Fixtures.paper(authors: ["Ada", "Bob"])), "Ada et al.")
        XCTAssertEqual(PaperPresentation.cardSubtitle(Fixtures.paper(authors: ["Ada"])), "Ada")
        XCTAssertEqual(PaperPresentation.cardSubtitle(Fixtures.paper(depth: "summary")), "Summary")
        XCTAssertEqual(PaperPresentation.cardSubtitle(Fixtures.paper(filename: "f.pdf", depth: nil)), "f.pdf")
        XCTAssertEqual(PaperPresentation.listSubtitle(Fixtures.paper(authors: ["A", "B"])), "A, B")
        XCTAssertEqual(PaperPresentation.listSubtitle(Fixtures.paper(filename: nil)), "—")
    }

    func testNewAndCoverBadges() {
        XCTAssertTrue(PaperPresentation.isNew(Fixtures.paper(read: false)))
        XCTAssertFalse(PaperPresentation.isNew(Fixtures.paper(read: true)))
        XCTAssertFalse(PaperPresentation.isNew(Fixtures.paper(state: "running")))
        XCTAssertTrue(PaperPresentation.showsStatusBadgeOnCover(Fixtures.paper(state: "queued")))
        XCTAssertTrue(PaperPresentation.showsStatusBadgeOnCover(Fixtures.paper(state: "error")))
        XCTAssertFalse(PaperPresentation.showsStatusBadgeOnCover(Fixtures.paper()))
    }

    func testProgressStrip() {
        var p = Fixtures.paper(state: "running")
        p.progress = 0
        XCTAssertEqual(PaperPresentation.progressStrip(p), 0.02)         // a sliver while converting
        p.progress = 0.5
        XCTAssertEqual(PaperPresentation.progressStrip(p), 0.5)
        var done = Fixtures.paper()
        done.progress = 30; done.duration = 120
        XCTAssertEqual(PaperPresentation.progressStrip(done), 0.25)     // listened fraction
        done.progress = 0
        XCTAssertEqual(PaperPresentation.progressStrip(done), 0)         // hidden
    }

    func testTitleEdits() {
        XCTAssertNil(PaperPresentation.titleEdit("   ", current: "Old"))
        XCTAssertEqual(PaperPresentation.titleEdit("  New \n Title ", current: "Old")?.clean, "New Title")
        XCTAssertEqual(PaperPresentation.titleEdit("Old ", current: "Old")?.changed, false)
    }

    func testDetailsLabels() {
        XCTAssertEqual(PaperPresentation.doiURL("10.1/x")?.absoluteString, "https://doi.org/10.1/x")
        XCTAssertNil(PaperPresentation.doiURL(""))
        var p = Fixtures.paper()
        XCTAssertNil(PaperPresentation.publishedDate(p))
        p.publishedIso = "2018-06"
        XCTAssertEqual(PaperPresentation.publishedDate(p), "June 2018")
        p.publishedIso = "garbage"
        XCTAssertNil(PaperPresentation.publishedDate(p))
        XCTAssertEqual(PaperPresentation.assetHelp("Audio", present: false), "No audio yet")
        XCTAssertEqual(PaperPresentation.coverHelp(Fixtures.paper()), "Double-click to open the PDF")
        XCTAssertEqual(PaperPresentation.otherPapersLabel(3), "3 papers")
        XCTAssertNil(PaperPresentation.otherPapersLabel(1))
    }

    func testAuthorsPreview() {
        let many = (1...8).map { "A\($0)" }
        XCTAssertEqual(PaperPresentation.visibleAuthors(many, showAll: false).count, 5)
        XCTAssertEqual(PaperPresentation.visibleAuthors(many, showAll: true).count, 8)
        XCTAssertEqual(PaperPresentation.authorsToggleTitle(count: 8, showingAll: false), "Show all 8 authors")
        XCTAssertEqual(PaperPresentation.authorsToggleTitle(count: 8, showingAll: true), "Show fewer")
        XCTAssertNil(PaperPresentation.authorsToggleTitle(count: 5, showingAll: false))
    }

    func testSuggestedTagsAreTheMostUsedMissingOnes() {
        let p = Fixtures.paper(tags: ["ml"])
        let counts = [("ml", 9), ("nlp", 4), ("cv", 7), ("rl", 1), ("db", 2), ("os", 3), ("hci", 5)]
        XCTAssertEqual(PaperPresentation.suggestedTags(for: p, tagCounts: counts), ["cv", "hci", "nlp", "os", "db"])
    }

    func testSectionsAndActions() {
        XCTAssertTrue(PaperPresentation.showsConversionCard(Fixtures.paper(state: "error")))
        XCTAssertFalse(PaperPresentation.showsConversionCard(Fixtures.paper()))
        XCTAssertFalse(PaperPresentation.showsEpisodeCard(Fixtures.paper(hasScript: false, hasAudio: false)))
        XCTAssertTrue(PaperPresentation.canRegenerateAudio(Fixtures.paper(), anyConversionRunning: false))
        XCTAssertFalse(PaperPresentation.canRegenerateAudio(Fixtures.paper(), anyConversionRunning: true))
        XCTAssertFalse(PaperPresentation.canRegenerateAudio(Fixtures.paper(hasScript: false), anyConversionRunning: false))
        XCTAssertFalse(PaperPresentation.canRerun(Fixtures.paper(state: "running")))
        XCTAssertTrue(PaperPresentation.rerunNeedsConfirmation(Fixtures.paper()))
        XCTAssertFalse(PaperPresentation.rerunNeedsConfirmation(Fixtures.paper(hasScript: false, hasAudio: false)))
    }

    func testToggleAndButtonLabels() {
        XCTAssertEqual(PaperPresentation.listenedToggle(Fixtures.paper(read: true)).title, "Mark as unlistened")
        XCTAssertEqual(PaperPresentation.favoriteToggle(Fixtures.paper(favorite: false)).title, "Add to favorites")
        XCTAssertEqual(PaperPresentation.favoriteButton(Fixtures.paper(favorite: true)).title, "Favorited")
        var p = Fixtures.paper()
        XCTAssertEqual(PaperPresentation.playButton(p, isPlaying: false).title, "Play")
        p.progress = 42
        XCTAssertEqual(PaperPresentation.playButton(p, isPlaying: false).title, "Resume")
        XCTAssertEqual(PaperPresentation.playButton(p, isPlaying: true).icon, "pause.fill")
    }

    func testStatusWording() {
        XCTAssertEqual(PaperPresentation.statusText(Fixtures.paper(state: "queued")), "Queued")
        XCTAssertEqual(PaperPresentation.statusText(Fixtures.paper(state: "running")), "Converting")
        XCTAssertEqual(PaperPresentation.statusText(Fixtures.paper(read: false)), "Ready")
        XCTAssertEqual(PaperPresentation.statusText(Fixtures.paper(read: true)), "Listened")
        XCTAssertEqual(PaperPresentation.statusText(Fixtures.paper(state: "error")), "Failed")
        XCTAssertEqual(PaperPresentation.statusText(Fixtures.paper(state: "draft")), "Not converted")
        XCTAssertEqual(PaperPresentation.statusIcon(Fixtures.paper(state: "error")), "exclamationmark.triangle.fill")
        var failed = Fixtures.paper(state: "error")
        XCTAssertEqual(PaperPresentation.failureMessage(failed), "Something went wrong while converting this paper.")
        failed.message = "msg"
        XCTAssertEqual(PaperPresentation.failureMessage(failed), "msg")
        failed.statusError = "err"
        XCTAssertEqual(PaperPresentation.failureMessage(failed), "err")
    }
}

final class ConversionAndEpisodeTests: PapertalkTestCase {
    func testStages() {
        XCTAssertEqual(ConversionPresentation.currentStage("audio"), 4)
        XCTAssertEqual(ConversionPresentation.currentStage(nil), 0)
        XCTAssertEqual(ConversionPresentation.currentStage("bogus"), 0)
        XCTAssertEqual(ConversionPresentation.state(ofStage: 1, current: 2), .done)
        XCTAssertEqual(ConversionPresentation.state(ofStage: 2, current: 2), .current)
        XCTAssertEqual(ConversionPresentation.state(ofStage: 3, current: 2), .pending)
        XCTAssertEqual(ConversionPresentation.barValue(0), 0.02)
        XCTAssertEqual(ConversionPresentation.barValue(3), 1)
        XCTAssertEqual(ConversionPresentation.percentLabel(0.456), "46%")
    }

    private func episode(progress: Double = 0, duration: Double = 0, read: Bool = false, hasAudio: Bool = true,
                         loaded: Bool = false, time: Double = 0, playerDuration: Double = 0, playing: Bool = false) -> EpisodeProgress {
        var p = Fixtures.paper(read: read, hasAudio: hasAudio)
        p.progress = progress; p.duration = duration
        return EpisodeProgress(paper: p, isLoaded: loaded, playerTime: time, playerDuration: playerDuration, playerIsPlaying: playing)
    }

    func testUsesLivePlayerOnlyWhenLoaded() {
        XCTAssertEqual(episode(progress: 60, duration: 600).position, 60)
        XCTAssertEqual(episode(progress: 60, duration: 600, loaded: true, time: 90, playerDuration: 610).position, 90)
        XCTAssertEqual(episode(progress: 60, duration: 600, loaded: true, time: 90, playerDuration: 610).length, 610)
        XCTAssertEqual(episode(progress: 60, duration: 600, loaded: true, time: 0, playerDuration: 0).position, 60)
    }

    func testLabels() {
        let e = episode(progress: 150, duration: 600)
        XCTAssertEqual(e.fraction, 0.25)
        XCTAssertEqual(e.percentLabel, "25%")
        XCTAssertEqual(e.elapsedLabel, "2:30")
        XCTAssertEqual(e.remainingLabel, "−7:30")
        XCTAssertNil(episode().percentLabel)
        XCTAssertEqual(episode().remainingLabel, "–:––")
    }

    func testHeadlines() {
        XCTAssertEqual(episode(hasAudio: true).headline, "Ready to play")
        XCTAssertEqual(episode(hasAudio: false).headline, "Script ready")
        XCTAssertEqual(episode(duration: 600, read: true).headline, "Listened")
        XCTAssertEqual(episode(duration: 600).headline, "10 min episode")
        XCTAssertEqual(episode(progress: 300, duration: 600).headline, "5 min left")
        XCTAssertEqual(episode(progress: 570, duration: 600).headline, "Almost done")
    }

    func testTurnLabel() {
        XCTAssertEqual(EpisodeProgress.turnLabel(activeTurn: 2, turnCount: 40), "Turn 3 of 40")
        XCTAssertNil(EpisodeProgress.turnLabel(activeTurn: -1, turnCount: 40))
        XCTAssertNil(EpisodeProgress.turnLabel(activeTurn: 0, turnCount: 0))
    }
}

final class PlayerPresentationTests: PapertalkTestCase {
    func testPlaybackStatus() {
        XCTAssertEqual(PlaybackStatus(isRendering: true, isBuffering: true, error: "x"), .preparingFirstSection)
        XCTAssertEqual(PlaybackStatus(isRendering: false, isBuffering: true, error: "x"), .preparingNextSection)
        XCTAssertEqual(PlaybackStatus(isRendering: false, isBuffering: false, error: "x"), .failed("x"))
        XCTAssertEqual(PlaybackStatus(isRendering: false, isBuffering: false, error: nil), .idle)
        XCTAssertEqual(PlaybackStatus.forPaper(isLoaded: false, isRendering: true, isBuffering: false, error: nil), .idle)
        XCTAssertNil(PlaybackStatus.idle.message)
    }

    func testTurnLabel() {
        let label = PlayerBarPresentation.turnLabel
        XCTAssertEqual(label(-1, 0, 0, false, false), "")
        XCTAssertEqual(label(4, 40, 40, false, false), "· 5 of 40")
        XCTAssertEqual(label(-1, 40, 12, false, false), "· 1 of 40 · voiced 12")     // live render
        XCTAssertEqual(label(4, 40, 12, false, true), "· 5 of 40")                  // stopped by an error
        XCTAssertEqual(label(4, 40, 12, true, false), "· preparing the next section…")
    }

    func testTransportRules() {
        XCTAssertFalse(PlayerBarPresentation.canSkipBack(activeTurn: -1))
        XCTAssertFalse(PlayerBarPresentation.canSkipBack(activeTurn: 0))
        XCTAssertTrue(PlayerBarPresentation.canSkipBack(activeTurn: 1))
        XCTAssertTrue(PlayerBarPresentation.canSkipForward(activeTurn: 1, turnCount: 3))
        XCTAssertFalse(PlayerBarPresentation.canSkipForward(activeTurn: 2, turnCount: 3))
        XCTAssertFalse(PlayerBarPresentation.canPlay(isRendering: true, turnCount: 3))
        XCTAssertFalse(PlayerBarPresentation.canPlay(isRendering: false, turnCount: 0))
        XCTAssertEqual(PlayerBarPresentation.playButton(isPlaying: true).help, "Pause")
        XCTAssertEqual(PlayerBarPresentation.timeLabel(65, of: 600), "1:05 / 10:00")
    }

    func testStatusLine() {
        XCTAssertEqual(PlayerBarPresentation.line(isRendering: true, error: nil, renderedCount: 0),
                       .preparing("Preparing the first section…"))
        XCTAssertEqual(PlayerBarPresentation.line(isRendering: false, error: "boom", renderedCount: 0), .failed("boom"))
        // Some sections voiced before the error: keep the scrubber so they stay playable.
        XCTAssertEqual(PlayerBarPresentation.line(isRendering: false, error: "boom", renderedCount: 5), .scrubber)
    }

    func testBottomBarContent() {
        let run = Fixtures.paper(id: "run", state: "running")
        let playing = Fixtures.paper(id: "play")
        let selected = Fixtures.paper(id: "sel")
        XCTAssertEqual(BottomBarContent(activeImport: run, playing: playing, selected: selected),
                       .playerAndImport(playing: playing, importing: run))
        XCTAssertEqual(BottomBarContent(activeImport: run, playing: nil, selected: selected), .importOnly(run))
        XCTAssertEqual(BottomBarContent(activeImport: run, playing: run, selected: nil), .importOnly(run))
        XCTAssertEqual(BottomBarContent(activeImport: nil, playing: playing, selected: selected), .player(playing))
        XCTAssertEqual(BottomBarContent(activeImport: nil, playing: nil, selected: selected), .player(selected))
        XCTAssertEqual(BottomBarContent(activeImport: nil, playing: nil, selected: nil), .hidden)
    }

    func testPlayerPane() {
        var p = Fixtures.paper()
        XCTAssertEqual(PlayerPane(paper: p, playerHasAudio: true), .loaded)
        XCTAssertEqual(PlayerPane(paper: p, playerHasAudio: false), .ready(playTitle: "Play", detail: "Ready to play"))
        p.duration = 600
        XCTAssertEqual(PlayerPane(paper: p, playerHasAudio: false), .ready(playTitle: "Play", detail: "10:00 episode"))
        p.progress = 90
        XCTAssertEqual(PlayerPane(paper: p, playerHasAudio: false), .ready(playTitle: "Resume", detail: "Resume at 1:30 of 10:00"))
        XCTAssertEqual(PlayerPane(paper: Fixtures.paper(state: "running"), playerHasAudio: false),
                       .unavailable("Episode is being produced…"))
        XCTAssertEqual(PlayerPane(paper: Fixtures.paper(hasScript: false, hasAudio: false), playerHasAudio: false),
                       .unavailable("No episode for this paper yet"))
    }

    func testImportProgress() {
        XCTAssertNil(ImportProgressPresentation.counter(index: 0, count: 1))
        XCTAssertEqual(ImportProgressPresentation.counter(index: 4, count: 3), "2/3")
        var p = Fixtures.paper(state: "running")
        p.stage = nil
        XCTAssertEqual(ImportProgressPresentation.stage(p), stageLabel("extract"))
    }
}

final class TranscriptPresentationTests: PapertalkTestCase {
    func testSpeakersTextAndLog() {
        let t = Transcript(paperTitle: "T",
                           speakers: [Transcript.Speaker(name: "Host", persona: nil)],
                           segments: [Transcript.Segment(title: "Intro", turns: [
                               Transcript.Turn(speaker: "Guest", text: "Hi."),
                               Transcript.Turn(speaker: "Host", text: "Hello."),
                           ])])
        XCTAssertEqual(TranscriptPresentation.speakerNames(t), ["Host", "Guest"])
        XCTAssertEqual(TranscriptPresentation.segmentCount(t), "1 segment")
        XCTAssertEqual(TranscriptPresentation.segmentNumber(0), "01")
        XCTAssertEqual(TranscriptPresentation.speakerInitial("guest"), "G")
        XCTAssertEqual(TranscriptPresentation.plainText(t), "1. Intro\n\nGuest: Hi.\n\nHost: Hello.")
        XCTAssertEqual(TranscriptPresentation.logText([]), "No activity yet.")
        XCTAssertEqual(TranscriptPresentation.logText(["a", "b"]), "a\nb")
    }
}

final class FormTests: PapertalkTestCase {
    func testImportForm() {
        var f = ImportForm()
        XCTAssertFalse(f.canStart)
        XCTAssertEqual(f.startHelp, "Choose a PDF first")
        XCTAssertNil(f.submission)
        f.setFile(name: "p.pdf", data: Data(count: 2048))
        XCTAssertTrue(f.canStart)
        XCTAssertEqual(f.startHelp, "")
        XCTAssertNotNil(f.fileSizeLabel)
        f.depth = .custom
        XCTAssertFalse(f.canStart)                      // custom needs a description
        XCTAssertEqual(f.startHelp, "Describe the depth you want first")
        XCTAssertFalse(f.canSavePreset)
        f.depthNote = "  only results "
        XCTAssertTrue(f.canStart)
        XCTAssertTrue(f.canSavePreset)
        XCTAssertEqual(f.submission?.filename, "p.pdf")
        XCTAssertEqual(f.submission?.depth, .custom)
    }

    func testImportFormLLMWarning() {
        var f = ImportForm()
        XCTAssertTrue(f.showsNoLLMWarning(llmBaseURL: "  "))
        XCTAssertFalse(f.showsNoLLMWarning(llmBaseURL: "http://llm"))
        f.depth = .direct                               // direct read doesn't use the LLM
        XCTAssertFalse(f.showsNoLLMWarning(llmBaseURL: ""))
        XCTAssertEqual(Set(Depth.allCases.map(ImportForm.icon(for:))).count, Depth.allCases.count)
    }

    func testPDFFileRead() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.pdf")
        try Data("%PDF".utf8).write(to: url)
        XCTAssertEqual(try PDFFile.read(url), Data("%PDF".utf8))
        XCTAssertThrowsError(try PDFFile.read(dir.appendingPathComponent("missing.pdf"))) { error in
            XCTAssertEqual(error.localizedDescription, "Could not read missing.pdf")
        }
    }

    func testMetadataForm() {
        var p = Fixtures.paper(title: "T", authors: ["Ada", "Bob"])
        p.affiliations = ["UCL"]
        var f = MetadataForm(p)
        XCTAssertEqual(f.authors, "Ada\nBob")
        f.authors = " Ada \n\n  Grace\n "
        XCTAssertEqual(f.authorList, ["Ada", "Grace"])
        XCTAssertEqual(f.affiliationList, ["UCL"])
    }

    func testLLMSettingsFormLoadsEachKeySource() {
        let typed = LLMSettingsForm(LLMSettings(baseUrl: "u", apiKey: "sk", model: "m", keyEnv: ""), setEnvVars: [])
        XCTAssertEqual(typed.keySource, .manual)
        XCTAssertEqual(typed.manualKey, "sk")
        let env = LLMSettingsForm(LLMSettings(baseUrl: "u", apiKey: "", model: "m", keyEnv: "MY_KEY"), setEnvVars: [])
        XCTAssertEqual(env.keySource, .env)
        XCTAssertEqual(env.envOptions, ["MY_KEY"])      // kept even though it isn't set now
        let none = LLMSettingsForm(LLMSettings(baseUrl: "", apiKey: "", model: "", keyEnv: ""), setEnvVars: [])
        XCTAssertEqual(none.keySource, .none)
        XCTAssertFalse(none.canFetchModels)
    }

    func testLLMSettingsFormRules() {
        var f = LLMSettingsForm(LLMSettings(baseUrl: " http://llm ", apiKey: "", model: " m ", keyEnv: ""),
                                setEnvVars: ["LLM_API_KEY", "OPENWEBUI_API_KEY"])
        f.keySource = .env
        f.keySourceChanged()
        XCTAssertEqual(f.selectedEnv, "LLM_API_KEY")    // first available picked
        XCTAssertEqual(f.effectiveKey(environment: ["LLM_API_KEY": "from-env"]), "from-env")
        XCTAssertEqual(f.settings, LLMSettings(baseUrl: "http://llm", apiKey: "", model: "m", keyEnv: "LLM_API_KEY"))

        f.keySource = .manual
        f.manualKey = " sk-typed "
        XCTAssertEqual(f.effectiveKey(environment: [:]), "sk-typed")
        XCTAssertEqual(f.settings.apiKey, "sk-typed")
        XCTAssertEqual(f.settings.keyEnv, "")           // only the chosen source is saved

        f.model = "gone"
        XCTAssertNil(f.applyModels(["a", "b"]))
        XCTAssertEqual(f.model, "a")                    // unavailable model → first offered
        f.model = "b"
        _ = f.applyModels(["a", "b"])
        XCTAssertEqual(f.model, "b")                    // kept when offered
        XCTAssertEqual(f.applyModels([]), "No models returned by /models")
    }

    func testServerSettingsForm() {
        var f = ServerSettingsForm(ServerConfig(apiBase: "", token: ""))
        XCTAssertEqual(f.mode, .local)
        XCTAssertEqual(f.summary, "This Mac")
        f.apiBase = " http://host:9170/// "
        XCTAssertEqual(f.config.apiBase, "")            // still local until switched
        XCTAssertEqual(f.configFromURL.apiBase, "http://host:9170")
        f.mode = .remote
        XCTAssertEqual(f.config.apiBase, "http://host:9170")
        XCTAssertEqual(f.summary, "http://host:9170///")
        f.apiBase = ""
        XCTAssertEqual(f.summary, "Remote (no URL)")
        XCTAssertEqual(ServerSettingsForm(ServerConfig(apiBase: "http://x", token: "t")).mode, .remote)
    }

    func testSetupSteps() {
        XCTAssertEqual(SetupStep.storage.next, .llm)
        XCTAssertEqual(SetupStep.llm.next, .voices)
        XCTAssertEqual(SetupStep.voices.next, .review)
        XCTAssertEqual(SetupStep.review.next, nil)
        XCTAssertEqual(SetupStep.llm.previous, .storage)
        XCTAssertEqual(SetupStep.voices.previous, .llm)
        XCTAssertEqual(SetupStep.review.previous, .voices)
        XCTAssertNil(SetupStep.storage.previous)
        XCTAssertTrue(SetupStep.voices.canSkip)
        XCTAssertFalse(SetupStep.review.canSkip)
        XCTAssertEqual(SetupStep.llm.nextTitle, "Continue")
        XCTAssertEqual(SetupStep.voices.nextTitle, "Review")
        XCTAssertEqual(SetupStep.review.nextTitle, "Finish")
        XCTAssertEqual(SetupStep.llmSummary(LLMSettings(baseUrl: "", apiKey: "", model: "", keyEnv: "")).map(\.value),
                       ["Not configured (read-through)"])
        XCTAssertEqual(SetupStep.llmSummary(LLMSettings(baseUrl: "u", apiKey: "", model: "", keyEnv: "")).map(\.value),
                       ["u", "—"])
    }

    func testPresetsAndClearData() {
        let clean = PresetsForm.clean([(" A ", " text "), ("", "x"), ("B", "  "), ("A", "dup")])
        XCTAssertEqual(clean.map(\.name), ["A"])
        XCTAssertEqual(clean.first?.text, "text")
        XCTAssertEqual(ClearDataPresentation.voiceModels(bytes: 0), "Not downloaded")
        XCTAssertFalse(ClearDataPresentation.canDeleteVoiceModels(bytes: 0, conversionRunning: false))
        XCTAssertFalse(ClearDataPresentation.canDeleteVoiceModels(bytes: 10, conversionRunning: true))
        XCTAssertTrue(ClearDataPresentation.canDeleteVoiceModels(bytes: 10, conversionRunning: false))
        XCTAssertEqual(ClearDataPresentation.deleteVoiceModelsHelp(conversionRunning: true), "Wait for conversions to finish")
    }
}

final class CastFormTests: PapertalkTestCase {
    private func form(authors: [String] = ["Ada Lovelace", "William Smith"],
                      genders: [String: String] = ["Ada Lovelace": "female", "William Smith": "male"],
                      guestGender: String? = "female") -> CastForm {
        CastForm(proposals: [ProposedSpeaker(role: "Interviewer", gender: "female", name: "Jordan"),
                             ProposedSpeaker(role: "Scientist", gender: guestGender, name: "Ada")],
                 authors: authors, authorGenders: genders)
    }

    func testPickingAnotherAuthorTakesTheirGenderAndVoice() {
        var f = form()
        let guest = f.rows[1].id
        f.rename(guest, to: "William Smith")
        XCTAssertEqual(f.rows[1].gender, "male")
        XCTAssertEqual(KokoroSpeech.voiceGender(f.rows[1].voice), "male")
        XCTAssertNotEqual(f.rows[1].voice, f.rows[0].voice)
    }

    func testRenamingTheHostOrTypingANameKeepsTheVoice() {
        var f = form()
        let host = f.rows[0]
        f.rename(host.id, to: "William")                // the host's name is typed, not an author
        XCTAssertEqual(f.rows[0].voice, host.voice)
        let guest = f.rows[1]
        f.rename(guest.id, to: "Someone Else")          // not one of the authors
        XCTAssertEqual(f.rows[1].voice, guest.voice)
    }

    func testSetGenderOnlyChangesAMismatchedVoice() {
        var f = form()
        let guest = f.rows[1]
        f.setGender(guest.id, "female")                 // already female: keep the voice
        XCTAssertEqual(f.rows[1].voice, guest.voice)
        f.setGender(guest.id, "male")
        XCTAssertEqual(KokoroSpeech.voiceGender(f.rows[1].voice), "male")
        f.setGender(f.rows[0].id, "male")               // host becomes male: signature male voice, not the guest's
        XCTAssertEqual(KokoroSpeech.voiceGender(f.rows[0].voice), "male")
        XCTAssertNotEqual(f.rows[0].voice, f.rows[1].voice)
    }

    func testIssuesInPriorityOrder() {
        var f = form(guestGender: nil)
        XCTAssertEqual(f.issue, .unknownGender("Ada"))
        XCTAssertEqual(f.note.severity, .warning)
        XCTAssertTrue(f.canConfirm)                     // a warning doesn't block
        f.rename(f.rows[1].id, to: "Jordan")
        XCTAssertEqual(f.issue, .duplicateName)
        XCTAssertFalse(f.canConfirm)
        f.rename(f.rows[1].id, to: "  ")
        XCTAssertEqual(f.issue, .emptyName)
        XCTAssertEqual(f.note.text, "Every speaker needs a name.")
    }

    func testSharedVoiceWarnsAndCastIsTrimmed() {
        var f = form()
        f.setVoice(f.rows[1].id, f.rows[0].voice)
        XCTAssertEqual(f.issue, .sharedVoice)
        f.rename(f.rows[1].id, to: "  Ada ")
        XCTAssertEqual(f.cast.map(\.name), ["Jordan", "Ada"])
        XCTAssertEqual(form().issue, nil)
        XCTAssertEqual(form().note.severity, .info)
    }

    func testAuthorPickerDetails() {
        let f = form()
        XCTAssertFalse(f.picksFromAuthors(f.rows[0]))   // host: typed
        XCTAssertTrue(f.picksFromAuthors(f.rows[1]))
        XCTAssertEqual(f.authorPlaceholder(f.rows[1]), "Ada")   // LLM's first-name pick isn't an author entry
        XCTAssertFalse(form(authors: []).picksFromAuthors(form(authors: []).rows[1]))
        XCTAssertEqual(CastForm.genderHelp(CastForm.Row(role: "x", name: "", voice: "af_heart", gender: nil)),
                       "Gender unknown — pick one so the voice fits")
        XCTAssertEqual(CastForm.voiceHelp("bm_george"), "British · male")
    }
}

final class PaceAndSampleTests: PapertalkTestCase {
    func testSpeakingPace() {
        XCTAssertEqual(SpeakingPacePresentation.label(1.25), "1.25×")
        XCTAssertTrue(SpeakingPacePresentation.isDefault(PlayerController.defaultSpeed))
        XCTAssertFalse(SpeakingPacePresentation.isDefault(1.0))
        XCTAssertNil(SpeakingPacePresentation.warning(1.5))
        XCTAssertTrue(SpeakingPacePresentation.warning(2.0)?.contains("about 14 minutes") == true)
    }

    func testVoiceSampleButton() {
        let generating = PlayerController.PreviewPhase.generating("af_bella")
        XCTAssertEqual(VoiceSamplePresentation.phase(generating, for: "af_bella"), generating)
        XCTAssertNil(VoiceSamplePresentation.phase(generating, for: "am_puck"))   // another voice's sample
        XCTAssertEqual(VoiceSamplePresentation.label(generating, loadingModel: true), "Loading voices…")
        XCTAssertEqual(VoiceSamplePresentation.label(generating, loadingModel: false), "Generating…")
        XCTAssertEqual(VoiceSamplePresentation.label(nil, loadingModel: false), "Sample")
        XCTAssertEqual(VoiceSamplePresentation.help(.failed("af_bella", "no model"), voice: "af_bella"),
                       "Couldn't play the sample: no model")
        XCTAssertTrue(VoiceSamplePresentation.tapStops(.playing("af_bella")))
        XCTAssertFalse(VoiceSamplePresentation.tapStops(.failed("af_bella", "x")))
        XCTAssertFalse(VoiceSamplePresentation.tapStops(nil))
    }
}

/// What Control Center's Now Playing is told, and when it's worth telling it.
final class NowPlayingPresentationTests: PapertalkTestCase {
    private func info(elapsed: Double = 10, advancing: Bool = true, duration: Double = 600) -> NowPlayingInfo {
        NowPlayingInfo(paperId: "p", title: "T", artist: nil, duration: duration, elapsed: elapsed, isAdvancing: advancing)
    }

    func testInfoNeedsALoadedEpisode() {
        let p = Fixtures.paper(title: "Attention")
        XCTAssertNil(NowPlayingPresentation.info(paper: nil, turnCount: 3, isPlaying: true, isBuffering: false,
                                                 currentTime: 1, duration: 10))
        XCTAssertNil(NowPlayingPresentation.info(paper: p, turnCount: 0, isPlaying: false, isBuffering: false,
                                                 currentTime: 0, duration: 0))
    }

    func testInfoFromPaper() {
        let p = Fixtures.paper(title: "Attention", authors: ["A", "B", "C", "D"])
        let i = NowPlayingPresentation.info(paper: p, turnCount: 3, isPlaying: true, isBuffering: false,
                                            currentTime: 12, duration: 300)
        XCTAssertEqual(i, NowPlayingInfo(paperId: p.id, title: "Attention", artist: "A, B, C et al.",
                                         duration: 300, elapsed: 12, isAdvancing: true))
        let untitled = Fixtures.paper(title: nil, filename: "x.pdf")
        let u = NowPlayingPresentation.info(paper: untitled, turnCount: 1, isPlaying: false, isBuffering: false,
                                            currentTime: 400, duration: 300)
        XCTAssertEqual(u?.title, "x.pdf")
        XCTAssertNil(u?.artist)
        XCTAssertEqual(u?.elapsed, 300, "elapsed stays inside the episode")
        XCTAssertEqual(u?.isAdvancing, false)
    }

    func testBufferingIsNotAdvancing() {
        let i = NowPlayingPresentation.info(paper: Fixtures.paper(), turnCount: 3, isPlaying: true, isBuffering: true,
                                            currentTime: 5, duration: 50)
        XCTAssertEqual(i?.isAdvancing, false)
    }

    func testNeedsPublishOnLoadAndClear() {
        XCTAssertFalse(NowPlayingPresentation.needsPublish(nil, after: nil, secondsSince: 5))
        XCTAssertTrue(NowPlayingPresentation.needsPublish(info(), after: nil, secondsSince: 0))
        XCTAssertTrue(NowPlayingPresentation.needsPublish(nil, after: info(), secondsSince: 0))
    }

    func testNeedsPublishIgnoresSteadyPlayback() {
        XCTAssertFalse(NowPlayingPresentation.needsPublish(info(elapsed: 14.8), after: info(elapsed: 10), secondsSince: 5))
        XCTAssertFalse(NowPlayingPresentation.needsPublish(info(elapsed: 10, advancing: false),
                                                           after: info(elapsed: 10, advancing: false), secondsSince: 30))
    }

    func testNeedsPublishOnSeekPauseAndEdits() {
        XCTAssertTrue(NowPlayingPresentation.needsPublish(info(elapsed: 100), after: info(elapsed: 10), secondsSince: 1),
                      "a seek forward")
        XCTAssertTrue(NowPlayingPresentation.needsPublish(info(elapsed: 0), after: info(elapsed: 10), secondsSince: 1),
                      "a skip back")
        XCTAssertTrue(NowPlayingPresentation.needsPublish(info(elapsed: 15, advancing: false),
                                                          after: info(elapsed: 10, advancing: false), secondsSince: 1),
                      "a seek while paused")
        XCTAssertTrue(NowPlayingPresentation.needsPublish(info(advancing: false), after: info(), secondsSince: 0))
        XCTAssertTrue(NowPlayingPresentation.needsPublish(info(duration: 700), after: info(), secondsSince: 0),
                      "a live render growing the episode")
        var renamed = info(); renamed.title = "New"
        XCTAssertTrue(NowPlayingPresentation.needsPublish(renamed, after: info(), secondsSince: 0))
    }

    func testSkipTargetStaysInside() {
        XCTAssertEqual(NowPlayingPresentation.skipTarget(from: 10, by: 15, duration: 100), 25)
        XCTAssertEqual(NowPlayingPresentation.skipTarget(from: 10, by: -15, duration: 100), 0)
        XCTAssertEqual(NowPlayingPresentation.skipTarget(from: 95, by: 15, duration: 100), 100)
    }

    func testPlayPauseCommands() {
        XCTAssertTrue(NowPlayingPresentation.shouldToggle(.play, isPlaying: false))
        XCTAssertFalse(NowPlayingPresentation.shouldToggle(.play, isPlaying: true))
        XCTAssertTrue(NowPlayingPresentation.shouldToggle(.pause, isPlaying: true))
        XCTAssertFalse(NowPlayingPresentation.shouldToggle(.pause, isPlaying: false))
        XCTAssertTrue(NowPlayingPresentation.shouldToggle(.toggle, isPlaying: true))
        XCTAssertTrue(NowPlayingPresentation.shouldToggle(.toggle, isPlaying: false))
    }
}
