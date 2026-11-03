// The details panel (inspector) on the right of the main window: everything about the selected
// paper and every action on it.

#if os(macOS)
import SwiftUI
import AppKit

/// Paper inspector (right-hand column), and the paper window's content.
///
/// Layout, top to bottom:
///   hero (colour wash + page cover + editable title + badges)
///   glass quick-action bar (play, PDF, transcript, favourite, edit)
///   conversion status (only while running / failed)
///   episode card (listening progress, resume)
/// In the inspector the paper's tags sit above the quick actions, read-only, and the bar has a
/// Details button that opens the paper window (where tags are edited and the activity log is).
/// The paper window lays it out wide instead, in three columns that each scroll on their own:
///   the paper (hero, quick actions, status, episode) · what it is (authors, details, tags) ·
///   what to do with it (audio, PDF management, library, activity).
struct DetailView: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper
    /// Opens the Edit paper sheet.
    var onEdit: () -> Void
    /// Shown in the paper window (every card) rather than the inspector (the essentials).
    var inWindow = false

    /// The sheet is driven by the loaded transcript itself, so it can never
    /// render before the data arrives (an `isPresented` flag + separate state
    /// could show the empty branch). Local, so it opens on this view's window.
    @State private var transcriptSheet: AppStore.TranscriptSheet?
    @State private var shownID: String?
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @State private var showAllAuthors = false
    @State private var showLog = false
    @State private var showCitation = false

    var body: some View {
        Group {
            if inWindow {
                HStack(alignment: .top, spacing: 0) {
                    column { paperColumn }
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                        .background(alignment: .top) { PaperBackdrop(paper: paper) }
                    Divider()
                    column {
                        if !paper.authors.isEmpty { authorsCard }
                        detailsCard
                        tagsCard
                    }
                    .padding(.top, 16)
                    Divider()
                    column {
                        manageCards
                        LogPane(lines: store.logLines(for: paper.id), isOpen: $showLog)
                    }
                    .padding(.top, 16)
                }
            } else {
                column { paperColumn }
                .background(alignment: .top) { PaperBackdrop(paper: paper) }
            }
        }
        .sheet(item: $transcriptSheet) { TranscriptSheetView(item: $0) }
        .sheet(isPresented: $showCitation) {
            CitationView(bibtex: paper.bibtex ?? "")
        }
        .onAppear { load(paper) }
        .onChange(of: paper.id) { _, _ in load(paper) }
        .onChange(of: paper.displayTitle) { _, newValue in
            if !titleFocused { titleDraft = newValue }
        }
        .onChange(of: paper.isActive) { _, active in
            if active { withAnimation(.snappy) { showLog = true } }
        }
    }

    /// One scrolling column of cards.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .animation(.snappy, value: paper.state)
        }
    }

    /// The paper itself: cover and title, quick actions, conversion status and the episode.
    @ViewBuilder private var paperColumn: some View {
        hero
        if !inWindow, !paper.tags.isEmpty { tagChips }
        QuickActionBar(player: store.player, paper: paper,
                       onPDF: openPDF, onTranscript: openTranscript, onMindMap: openMindMap, onEdit: onEdit,
                       onDetails: inWindow ? nil : { PaperWindow.present(paperId: paper.id, store: store) })
        if PaperPresentation.showsConversionCard(paper) {
            ConversionStatusCard(paper: paper)
                .transition(.blurReplace)
        }
        if PaperPresentation.showsEpisodeCard(paper) {
            EpisodeCard(player: store.player, paper: paper)
        }
    }

    /// Reset the panel's local state when another paper is shown.
    private func load(_ p: Paper) {
        guard shownID != p.id else { return }
        shownID = p.id
        titleDraft = p.displayTitle
        showAllAuthors = false
        showLog = p.isActive
    }

    /// Save the inline title edit (an empty one reverts).
    private func commitTitle() {
        titleDraft = store.commitTitleEdit(paper.id, draft: titleDraft)
    }

    // MARK: - Hero

    /// The cover, the editable title and the depth and date pills.
    private var hero: some View {
        VStack(spacing: 14) {
            PaperArtwork(paper: paper)
                .frame(width: 128)
                .clipShape(RoundedRectangle(cornerRadius: Theme.thumbRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.thumbRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openPDF() }
                .help(PaperPresentation.coverHelp(paper))

            VStack(spacing: 6) {
                TextField(L("Untitled"), text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(); titleFocused = false }
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    .help(L("Click to rename"))

                if !paper.authors.isEmpty {
                    Text(PaperPresentation.authorLine(paper.authors))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 6) {
                StatusBadge(paper: paper)
                if let d = paper.depthTitle {
                    pill(d, icon: "dial.medium")
                }
                if let date = PaperPresentation.publishedDate(paper) {
                    pill(date, icon: "calendar")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    /// A small labelled capsule under the title.
    private func pill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
    }

    // MARK: - Authors

    /// The authors, each opening their papers; long lists are folded.
    private var authorsCard: some View {
        let visible = PaperPresentation.visibleAuthors(paper.authors, showAll: showAllAuthors)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: L("Authors"), systemImage: "person.2", trailing: LibraryPresentation.badge(paper.authors.count))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, name in
                    AuthorRow(name: name, paperCount: store.paperCount(byAuthor: name)) {
                        store.showAuthor(name)
                    }
                }
            }
            if let toggle = PaperPresentation.authorsToggleTitle(count: paper.authors.count, showingAll: showAllAuthors) {
                Button(toggle) {
                    withAnimation(.snappy) { showAllAuthors.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .glassCard()
    }

    // MARK: - Details

    /// Affiliation, DOI, citation, file, dates and which assets exist.
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: L("Details"), systemImage: "info.circle")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                if !paper.affiliations.isEmpty {
                    detailRow(L("Affiliation")) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(paper.affiliations.enumerated()), id: \.offset) { _, a in
                                Text(a)
                            }
                        }
                    }
                }
                if !paper.doi.isEmpty {
                    detailRow("DOI") {
                        HStack(spacing: 6) {
                            if let url = PaperPresentation.doiURL(paper.doi) {
                                Link(paper.doi, destination: url).lineLimit(1).truncationMode(.middle)
                            } else {
                                Text(paper.doi)
                            }
                            CopyButton(value: paper.doi)
                        }
                    }
                    if PaperPresentation.showsCitation(paper) {
                        detailRow(L("LaTeX")) {
                            Button {
                                showCitation = true
                            } label: {
                                Label(L("Show citation"), systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                detailRow(L("File")) {
                    Text(PaperPresentation.fileLabel(paper)).lineLimit(1).truncationMode(.middle)
                }
                if let date = PaperPresentation.publishedDate(paper) {
                    detailRow(L("Published")) { Text(date) }
                }
                if let length = PaperPresentation.lengthLabel(paper) {
                    detailRow(L("Length")) { Text(length) }
                }
                detailRow(L("Assets")) {
                    HStack(spacing: 10) {
                        asset(L("PDF"), "doc.fill", paper.hasPdf)
                        asset(L("Transcript"), "text.quote", paper.hasScript)
                        asset(L("Audio"), "waveform", paper.hasAudio)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
        .glassCard()
    }

    /// A label and its value in the details grid.
    private func detailRow<V: View>(_ label: String, @ViewBuilder value: () -> V) -> GridRow<some View> {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// An asset with a mark for whether it exists.
    private func asset(_ label: String, _ icon: String, _ present: Bool) -> some View {
        Label(label, systemImage: present ? icon : "minus.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(present ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .help(PaperPresentation.assetHelp(label, present: present))
    }

    // MARK: - Tags

    /// The inspector's tags: centred chips that show each tag's papers; editing is in the window.
    private var tagChips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(paper.tags, id: \.self) { tag in
                TagChip(tag: tag, onSelect: { store.showTag(tag) })
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The paper's tags, the add field, and suggestions from the library's common tags.
    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: L("Tags"), systemImage: "number", trailing: LibraryPresentation.badge(paper.tags.count))
            FlowTags(
                tags: paper.tags,
                onSelect: { store.showTag($0) },
                onRemove: { store.removeTag(paper.id, $0) }
            ) {
                TagEntryField { store.addTag(paper.id, $0) }
            }
            let suggestedTags = PaperPresentation.suggestedTags(for: paper, tagCounts: store.tagCounts)
            if !suggestedTags.isEmpty {
                HStack(spacing: 6) {
                    Text(L("Suggested")).font(.caption2).foregroundStyle(.tertiary)
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(suggestedTags, id: \.self) { tag in
                            Button {
                                store.addTag(paper.id, tag)
                            } label: {
                                Text(PaperPresentation.suggestionLabel(tag)).font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
                        }
                    }
                }
            }
        }
        .glassCard()
    }

    // MARK: - Manage

    /// The actions on a paper, grouped by what they work on: the saved audio, new work from the
    /// PDF, and the paper as a library item (listened, Finder, delete).
    private var manageCards: some View {
        VStack(spacing: 14) {
            audioCard
            pdfCard
            libraryActions
        }
    }

    /// Regenerate, export and delete the episode's audio.
    private var audioCard: some View {
        manageGroup(L("Audio"), systemImage: "waveform") {
            ManageRow(title: L("Regenerate audio"), subtitle: L("Re-voice the existing script"),
                      icon: "waveform.badge.magnifyingglass", tint: .appAccent) {
                store.regenerateAudio(paper.id)
            }
            .disabled(!PaperPresentation.canRegenerateAudio(paper, anyConversionRunning: store.activeRun != nil))
            ManageRow(title: L("Export audio…"), subtitle: L("Save the episode as one M4A file with the paper's details"),
                      icon: "square.and.arrow.up", tint: .blue) {
                exportAudio()
            }
            .disabled(!EpisodeExport.canExport(paper))
            if PaperPresentation.canDeleteAudio(paper) {
                ManageRow(title: L("Delete audio"), subtitle: L("Free the space; keep the script"),
                          icon: "waveform.slash", tint: .orange) {
                    store.pendingConfirmation = .deleteAudio(paper)
                }
            }
        }
    }

    /// Everything that reads the PDF again with the LLM: a new script, the mind map, the metadata.
    private var pdfCard: some View {
        manageGroup(L("PDF management"), systemImage: "doc.text.magnifyingglass") {
            ManageRow(title: L("Rerun episode"), subtitle: L("Write a new script from the PDF"),
                      icon: "arrow.counterclockwise", tint: .indigo) {
                store.requestRerun(paper)
            }
            .disabled(!PaperPresentation.canRerun(paper))
            let mindMap = PaperPresentation.mindMapRow(paper, drawing: store.isDrawingMindMap(paper.id))
            ManageRow(title: mindMap.title, subtitle: mindMap.subtitle,
                      icon: "point.3.connected.trianglepath.dotted", tint: .purple) {
                store.createMindMap(paper.id)
            }
            .disabled(!store.canCreateMindMap(paper))
            ManageRow(title: L("Refresh metadata"), subtitle: L("Re-extract title, authors and DOI"),
                      icon: "arrow.clockwise", tint: .teal) {
                store.refreshMeta(paper.id)
            }
        }
    }

    /// The paper as a library item: listened, Finder, export, and Delete paper last, below a divider.
    private var libraryActions: some View {
        manageGroup(L("Library"), systemImage: "books.vertical") {
            let listened = PaperPresentation.listenedToggle(paper)
            ManageRow(title: listened.title, subtitle: nil, icon: listened.icon, tint: .green) {
                store.toggleRead(paper.id)
            }
            if store.isStandalone {
                ManageRow(title: L("Show in Finder"), subtitle: nil, icon: "folder", tint: .blue) {
                    store.revealInFinder(paper.id)
                }
            }
            ManageRow(title: L("Export paper…"), subtitle: L("Save it as a Papertalk file to share or keep"),
                      icon: "shippingbox", tint: .brown) {
                PaperPanels.exportPaper(paper, from: store)
            }
            .disabled(!PaperPresentation.canExportPaper(paper))
            Divider().padding(.vertical, 4)
            ManageRow(title: L("Delete paper"), subtitle: nil, icon: "trash", tint: .red, destructive: true) {
                store.pendingConfirmation = .delete(paper)
            }
        }
    }

    /// One titled glass card of `ManageRow`s.
    private func manageGroup<Rows: View>(_ title: String, systemImage: String,
                                         @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: title, systemImage: systemImage)
                .padding(.bottom, 2)
            VStack(spacing: 0) { rows() }
        }
        .glassCard(padding: 12)
    }

    // MARK: - Actions

    /// Open the stored PDF in its own window.
    private func openPDF() { PaperPanels.openPDF(paper, from: store) }

    /// Ask where to save the episode, then export it there.
    private func exportAudio() { PaperPanels.exportAudio(paper, from: store) }

    /// Open the transcript sheet with the script as it is on disk now.
    private func openTranscript() {
        // Always read the current file: a rerun may have replaced it.
        Task { transcriptSheet = await store.transcriptSheet(for: paper.id) }
    }

    /// Open the mind map window.
    private func openMindMap() { MindMapWindow.open(paperId: paper.id, store: store) }
}

// MARK: - Backdrop

/// Soft, per-paper colour wash behind the hero; fades out so the cards below
/// sit on the plain inspector material. Gives the glass something to refract.
private struct PaperBackdrop: View {
    let paper: Paper

    var body: some View {
        let a = Color.stable(for: paper.id, saturation: 0.55, brightness: 0.9)
        let b = Color.stable(for: paper.id + "·", saturation: 0.45, brightness: 0.8)
        MeshGradient(
            width: 3, height: 3,
            points: [
                SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0.5), SIMD2<Float>(0.6, 0.45), SIMD2<Float>(1, 0.5),
                SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 1), SIMD2<Float>(1, 1),
            ],
            colors: [
                a, Color.appAccent, b,
                b.opacity(0.8), a.opacity(0.7), Color.appAccent.opacity(0.6),
                .clear, .clear, .clear,
            ]
        )
        .opacity(0.45)
        .frame(height: 460)
        .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: paper.id)
        .allowsHitTesting(false)
    }
}

// MARK: - Quick actions

/// The glass action bar under the hero: play, PDF, transcript, mind map, favourite, edit.
private struct QuickActionBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PlayerController
    let paper: Paper
    /// Opens the PDF.
    var onPDF: () -> Void
    /// Opens the transcript sheet.
    var onTranscript: () -> Void
    /// Opens the mind map.
    var onMindMap: () -> Void
    /// Opens the Edit paper sheet.
    var onEdit: () -> Void
    /// Opens the paper window; nil inside that window, where there's nothing more to open.
    var onDetails: (() -> Void)?

    private var isLoaded: Bool { store.isLoaded(paper.id) }

    var body: some View {
        let play = PaperPresentation.playButton(paper, isPlaying: store.isPlaying(paper.id))
        let favorite = PaperPresentation.favoriteButton(paper)
        // Play is the main action and gets the full width; six round buttons in one row left
        // no room between them in a narrow inspector. Details, in the inspector, gets a wide row too.
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 10) {
                playButton(play.title, icon: play.icon, busy: isLoaded && player.isRendering,
                           enabled: PaperPresentation.isPlayable(paper))
                secondaryActions(favorite)
                if let onDetails { detailsButton(onDetails) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The large play/pause button; shows a spinner while the first turn is voiced.
    private func playButton(_ title: String, icon: String, busy: Bool, enabled: Bool) -> some View {
        Button(action: togglePlay) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title).font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .glassEffect(Glass.regular.tint(Color.appAccent).interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(title)
    }

    /// The wide button to the paper window: as big as Play but lightly tinted, so it stands out
    /// without competing with Play.
    private func detailsButton(_ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").font(.system(size: 15, weight: .semibold))
                Text(L("Details and actions…")).font(.headline)
            }
            .foregroundStyle(Color.appAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .glassEffect(Glass.regular.tint(Color.appAccent.opacity(0.18)).interactive(), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.45), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Authors, details, audio, PDF and library actions in their own window"))
    }

    /// The row of small icon buttons.
    private func secondaryActions(_ favorite: (title: String, icon: String)) -> some View {
        HStack(alignment: .top, spacing: 0) {
            action(L("PDF"), icon: "doc.text", enabled: paper.hasPdf, perform: onPDF)
            action(L("Transcript"), icon: "text.quote", enabled: paper.hasScript, perform: onTranscript)
            action(L("Mind map"), icon: "point.3.connected.trianglepath.dotted",
                   enabled: PaperPresentation.hasMindMap(paper), perform: onMindMap)
            action(favorite.title, icon: favorite.icon,
                   iconColor: paper.favorite ? Color.yellow : nil) {
                withAnimation(.snappy) { store.toggleFavorite(paper.id) }
            }
            action(L("Edit"), icon: "pencil", perform: onEdit)
        }
    }

    /// Play or pause this paper in the global player.
    private func togglePlay() { store.togglePlayback(paper.id) }

    /// A small icon button with its label under it.
    private func action(_ title: String, icon: String, enabled: Bool = true, iconColor: Color? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor ?? Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 42, height: 42)
                    .glassEffect(Glass.regular.interactive(), in: Circle())
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(title)
    }
}

// MARK: - Conversion status

/// While converting: the stage checklist and progress bar, with Stop. After a failure: why,
/// with Try again and Dismiss.
private struct ConversionStatusCard: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    private var currentIndex: Int { ConversionPresentation.currentStage(paper.stage) }

    var body: some View {
        if paper.isError { errorBody } else { runningBody }
    }

    /// The checklist of stages and the progress bar.
    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: L("Converting"), systemImage: "gearshape.2",
                         trailing: ConversionPresentation.percentLabel(paper.progress))
            ProgressView(value: ConversionPresentation.barValue(paper.progress))
                .tint(.appAccent)
                .animation(.easeInOut(duration: 0.25), value: paper.progress)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(ConversionPresentation.stages.enumerated()), id: \.offset) { i, s in
                    let state = ConversionPresentation.state(ofStage: i, current: currentIndex)
                    HStack(spacing: 8) {
                        Group {
                            switch state {
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .current: ProgressView().controlSize(.mini)
                            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 16)
                        Text(s.label)
                            .font(.callout.weight(state == .current ? .semibold : .regular))
                            .foregroundStyle(state == .pending ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                                               : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        Spacer()
                    }
                }
            }
            if let m = PaperPresentation.message(paper) {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button {
                store.stopConversion(paper.id)
            } label: {
                Label(PaperPresentation.stopTitle, systemImage: "stop.circle")
            }
            .buttonStyle(.glass)
        }
        .glassCard(tint: Color.appAccent.opacity(0.10))
    }

    /// What went wrong and the ways forward.
    private var errorBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(PaperPresentation.failureTitle(paper), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(PaperPresentation.failureMessage(paper))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    store.rerun(paper.id, fresh: false)
                } label: {
                    Label(L("Try again"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                Button(L("Dismiss")) { store.resetError(paper.id) }
                    .buttonStyle(.glass)
            }
        }
        .glassCard(tint: Color.red.opacity(0.12))
    }
}

// MARK: - Episode card

/// Listening progress for this paper, its playback status, and the live-audio warning.
private struct EpisodeCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PlayerController
    let paper: Paper

    private var isLoaded: Bool { store.isLoaded(paper.id) }

    var body: some View {
        let progress = EpisodeProgress(paper: paper, isLoaded: isLoaded, playerTime: player.currentTime,
                                       playerDuration: player.duration, playerIsPlaying: player.isPlaying)
        let fraction = progress.fraction
        let status = PlaybackStatus.forPaper(isLoaded: isLoaded, isRendering: player.isRendering,
                                             isBuffering: player.isBuffering, error: player.renderError)
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: L("Episode"), systemImage: "headphones", trailing: progress.percentLabel)
            HStack(alignment: .firstTextBaseline) {
                Text(progress.headline)
                    .font(.title3.weight(.semibold))
                Spacer()
                if isLoaded, let turn = EpisodeProgress.turnLabel(activeTurn: player.activeTurn, turnCount: player.turnCount) {
                    Text(turn)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(Color.appAccent.gradient)
                        .frame(width: max(6, geo.size.width * fraction))
                        .opacity(fraction > 0 ? 1 : 0)
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.2), value: fraction)
            HStack {
                Text(progress.elapsedLabel).monospacedDigit()
                Spacer()
                Text(progress.remainingLabel).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            switch status {
            case .idle:
                EmptyView()
            case .preparingFirstSection, .preparingNextSection:
                Label(status.message ?? "", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative)
            case .failed(let err):
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let warning = PaperPresentation.liveAudioWarning(paper) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard()
    }

}

// MARK: - Small pieces

/// Copies `value` and shows a check for a moment.
private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(value)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(L("Copy"))
    }
}

/// Presents a paper's LaTeX (BibTeX) citation with a copy button.
private struct CitationView: View {
    /// The citation as doi2bib returned it.
    let bibtex: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("LaTeX citation"), systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Label(L("Close"), systemImage: "xmark") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            TextEditor(text: .constant(bibtex))
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 480, minHeight: 220)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button {
                    Clipboard.copy(bibtex)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? L("Copied") : L("Copy citation"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

/// A row of a Manage card (Audio, PDF management, Library): icon, title, optional subtitle; red when destructive.
private struct ManageRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    /// Red, for actions that delete something.
    var destructive = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// Inline "+ Add tag" capsule that expands into a text field.
private struct TagEntryField: View {
    /// Called with the typed tag.
    var onAdd: (String) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(L("tag"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 90)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { text = ""; editing = false }
                    .onChange(of: focused) { _, f in if !f { submit(); editing = false } }
            } else {
                Button {
                    editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Label(L("Add tag"), systemImage: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: editing ? [] : [3, 3]))
        )
    }

    /// Add the typed tag and close the field.
    private func submit() {
        onAdd(text)   // the store tidies the tag and ignores blanks
        text = ""
    }
}

/// Inspector author line; opens that author's papers.
private struct AuthorRow: View {
    let name: String
    /// Their papers in the library, shown when more than this one.
    let paperCount: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AuthorAvatar(name: name)
                Text(name).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
                if let others = PaperPresentation.otherPapersLabel(paperCount) {
                    Text(others)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Show all papers by {0}", name))
        .contextMenu {
            Button(L("Copy name")) {
                Clipboard.copy(name)
            }
        }
    }
}

#endif
