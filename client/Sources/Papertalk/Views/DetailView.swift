import SwiftUI
import AppKit

/// Paper inspector (right-hand column).
///
/// Layout, top to bottom:
///   hero (colour wash + page cover + editable title + badges)
///   glass quick-action bar (play, PDF, transcript, favourite, edit)
///   conversion status (only while running / failed)
///   episode card (listening progress, resume)
///   authors · details · tags · manage · activity
struct DetailView: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper
    var onEdit: () -> Void

    @State private var transcript: Transcript?
    @State private var showTranscript = false
    @State private var shownID: String?
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @State private var showAllAuthors = false
    @State private var showLog = false
    @State private var showCitation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                QuickActionBar(player: store.player, paper: paper,
                               onPDF: openPDF, onTranscript: openTranscript, onEdit: onEdit)
                if paper.isActive || paper.isError {
                    ConversionStatusCard(paper: paper)
                        .transition(.blurReplace)
                }
                if paper.hasScript || paper.hasAudio {
                    EpisodeCard(player: store.player, paper: paper)
                }
                if !paper.authors.isEmpty { authorsCard }
                detailsCard
                tagsCard
                manageCard
                LogPane(lines: store.logLines(for: paper.id), isOpen: $showLog)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .animation(.snappy, value: paper.state)
        }
        .background(alignment: .top) { PaperBackdrop(paper: paper) }
        .sheet(isPresented: $showTranscript) {
            if let t = transcript {
                TranscriptView(transcript: t, title: paper.displayTitle)
            } else {
                ContentUnavailableView("No transcript yet", systemImage: "text.quote", description: Text("The transcript for this paper isn’t available."))
                    .frame(width: 700, height: 660)
            }
        }
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

    private func load(_ p: Paper) {
        guard shownID != p.id else { return }
        shownID = p.id
        transcript = nil
        titleDraft = p.displayTitle
        showAllAuthors = false
        showLog = p.isActive
        Task {
            transcript = await store.transcript(for: p.id)
        }
    }

    private func commitTitle() {
        let clean = titleDraft.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { titleDraft = paper.displayTitle; return }
        if clean != paper.displayTitle { store.saveTitle(paper.id, clean) }
        titleDraft = clean
    }

    // MARK: - Hero

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
                .help(paper.hasPdf ? "Double-click to open the PDF" : "")

            VStack(spacing: 6) {
                TextField("Untitled", text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(); titleFocused = false }
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    .help("Click to rename")

                if !paper.authors.isEmpty {
                    Text(authorLine)
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
                if let iso = paper.createdIso, !formatDate(iso).isEmpty {
                    pill(formatDate(iso), icon: "calendar")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private var authorLine: String {
        let a = paper.authors
        return a.count > 3 ? a.prefix(3).joined(separator: ", ") + " et al." : a.joined(separator: ", ")
    }

    private func pill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
    }

    // MARK: - Authors

    private var authorsCard: some View {
        let visible = showAllAuthors ? paper.authors : Array(paper.authors.prefix(5))
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Authors", systemImage: "person.2", trailing: "\(paper.authors.count)")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 10) {
                        AuthorAvatar(name: name)
                        Text(name).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .textSelection(.enabled)
                }
            }
            if paper.authors.count > 5 {
                Button(showAllAuthors ? "Show fewer" : "Show all \(paper.authors.count) authors") {
                    withAnimation(.snappy) { showAllAuthors.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .glassCard()
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Details", systemImage: "info.circle")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                if !paper.affiliations.isEmpty {
                    detailRow("Affiliation") {
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
                            if let url = URL(string: "https://doi.org/\(paper.doi)") {
                                Link(paper.doi, destination: url).lineLimit(1).truncationMode(.middle)
                            } else {
                                Text(paper.doi)
                            }
                            CopyButton(value: paper.doi)
                        }
                    }
                    if let bib = paper.bibtex, !bib.isEmpty {
                        detailRow("LaTeX") {
                            Button {
                                showCitation = true
                            } label: {
                                Label("Show citation", systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                detailRow("File") {
                    Text(paper.filename ?? "—").lineLimit(1).truncationMode(.middle)
                }
                if let iso = paper.createdIso, !formatDate(iso).isEmpty {
                    detailRow("Added") { Text(formatDate(iso)) }
                }
                if paper.duration > 0 {
                    detailRow("Length") { Text(formatT(paper.duration)) }
                }
                detailRow("Assets") {
                    HStack(spacing: 10) {
                        asset("PDF", "doc.fill", paper.hasPdf)
                        asset("Transcript", "text.quote", paper.hasScript)
                        asset("Audio", "waveform", paper.hasAudio)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
        .glassCard()
    }

    private func detailRow<V: View>(_ label: String, @ViewBuilder value: () -> V) -> GridRow<some View> {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func asset(_ label: String, _ icon: String, _ present: Bool) -> some View {
        Label(label, systemImage: present ? icon : "minus.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(present ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .help(present ? "\(label) available" : "No \(label.lowercased()) yet")
    }

    // MARK: - Tags

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Tags", systemImage: "number", trailing: paper.tags.isEmpty ? nil : "\(paper.tags.count)")
            FlowTags(
                tags: paper.tags,
                onSelect: { tag in
                    store.view = .tag
                    store.activeTag = tag
                },
                onRemove: { store.removeTag(paper.id, $0) }
            ) {
                TagEntryField { store.addTag(paper.id, $0) }
            }
            if !suggestedTags.isEmpty {
                HStack(spacing: 6) {
                    Text("Suggested").font(.caption2).foregroundStyle(.tertiary)
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(suggestedTags, id: \.self) { tag in
                            Button {
                                store.addTag(paper.id, tag)
                            } label: {
                                Text("+ \(tag)").font(.caption2)
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

    /// Most-used library tags this paper doesn't have yet.
    private var suggestedTags: [String] {
        store.tagCounts
            .filter { !paper.tags.contains($0.0) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { $0.0 }
    }

    // MARK: - Manage

    private var manageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Manage", systemImage: "slider.horizontal.3")
                .padding(.bottom, 2)
            VStack(spacing: 0) {
                ManageRow(title: "Regenerate audio", subtitle: "Re-voice the existing script",
                          icon: "waveform.badge.magnifyingglass", tint: .appAccent) {
                    store.regenerateAudio(paper.id)
                }
                .disabled(!paper.hasScript || store.activeRun != nil)
                ManageRow(title: "Rerun episode", subtitle: "Write a new script from the PDF",
                          icon: "arrow.counterclockwise", tint: .indigo) {
                    if paper.hasScript || paper.hasAudio {
                        store.pendingConfirmation = .rerun(paper)
                    } else {
                        store.rerun(paper.id)
                    }
                }
                .disabled(paper.isActive)
                ManageRow(title: "Refresh metadata", subtitle: "Re-extract title, authors and DOI",
                          icon: "arrow.clockwise", tint: .teal) {
                    store.refreshMeta(paper.id)
                }
                ManageRow(title: paper.read ? "Mark as unlistened" : "Mark as listened",
                          subtitle: nil, icon: paper.read ? "circle" : "checkmark.circle", tint: .green) {
                    store.toggleRead(paper.id)
                }
                if store.isStandalone {
                    ManageRow(title: "Show in Finder", subtitle: nil, icon: "folder", tint: .blue) {
                        store.revealInFinder(paper.id)
                    }
                }
                ManageRow(title: "Delete paper", subtitle: nil, icon: "trash", tint: .red, destructive: true) {
                    store.pendingConfirmation = .delete(paper)
                }
            }
        }
        .glassCard(padding: 12)
    }

    // MARK: - Actions

    private func openPDF() {
        guard paper.hasPdf else { return }
        Task {
            if let data = await store.pdfData(for: paper.id) {
                PDFViewerWindow.present(data: data, title: paper.displayTitle)
            }
        }
    }

    private func openTranscript() {
        Task {
            if transcript == nil { transcript = await store.transcript(for: paper.id) }
            showTranscript = true
        }
    }
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

private struct QuickActionBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PlayerController
    let paper: Paper
    var onPDF: () -> Void
    var onTranscript: () -> Void
    var onEdit: () -> Void

    private var isCurrent: Bool { store.playingPaperId == paper.id }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
    private var isPreparing: Bool { isCurrent && player.isRendering }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                action(isPlaying ? "Pause" : (paper.progress > 1 && !isPlaying ? "Resume" : "Play"),
                       icon: isPlaying ? "pause.fill" : "play.fill",
                       prominent: true, busy: isPreparing, enabled: paper.hasScript || paper.hasAudio,
                       perform: togglePlay)
                action("PDF", icon: "doc.text", enabled: paper.hasPdf, perform: onPDF)
                action("Transcript", icon: "text.quote", enabled: paper.hasScript, perform: onTranscript)
                action(paper.favorite ? "Favorited" : "Favorite",
                       icon: paper.favorite ? "star.fill" : "star",
                       iconColor: paper.favorite ? Color.yellow : nil) {
                    withAnimation(.snappy) { store.toggleFavorite(paper.id) }
                }
                action("Edit", icon: "pencil", perform: onEdit)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func togglePlay() { store.togglePlayback(paper.id) }

    private func action(_ title: String, icon: String, prominent: Bool = false, busy: Bool = false,
                        enabled: Bool = true, iconColor: Color? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: prominent ? 17 : 15, weight: .semibold))
                            .foregroundStyle(prominent ? AnyShapeStyle(Color.white)
                                             : AnyShapeStyle(iconColor ?? Color.primary))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: prominent ? 50 : 42, height: prominent ? 50 : 42)
                .glassEffect(prominent ? Glass.regular.tint(Color.appAccent).interactive()
                                       : Glass.regular.interactive(),
                             in: Circle())
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 74, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(title)
    }
}

// MARK: - Conversion status

private struct ConversionStatusCard: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    private static let stages: [(key: String, label: String)] = [
        ("extract", "Extract text"),
        ("notes", "Summarize"),
        ("outline", "Plan episode"),
        ("segments", "Write dialogue"),
        ("audio", "Synthesize voices"),
        ("finalize", "Finalize"),
    ]

    private var currentIndex: Int {
        Self.stages.firstIndex { $0.key == (paper.stage ?? "") } ?? 0
    }

    var body: some View {
        if paper.isError { errorBody } else { runningBody }
    }

    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Converting", systemImage: "gearshape.2",
                         trailing: "\(Int((max(0.02, paper.progress) * 100).rounded()))%")
            ProgressView(value: min(1, max(0.02, paper.progress)))
                .tint(.appAccent)
                .animation(.easeInOut(duration: 0.25), value: paper.progress)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        Group {
                            if i < currentIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if i == currentIndex {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 16)
                        Text(s.label)
                            .font(.callout.weight(i == currentIndex ? .semibold : .regular))
                            .foregroundStyle(i > currentIndex ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                                              : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        Spacer()
                    }
                }
            }
            if let m = paper.message, !m.isEmpty {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .glassCard(tint: Color.appAccent.opacity(0.10))
    }

    private var errorBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Conversion failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(paper.statusError ?? paper.message ?? "Something went wrong while converting this paper.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    store.rerun(paper.id, fresh: false)
                } label: {
                    Label("Try again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                Button("Dismiss") { store.resetError(paper.id) }
                    .buttonStyle(.glass)
            }
        }
        .glassCard(tint: Color.red.opacity(0.12))
    }
}

// MARK: - Episode card

private struct EpisodeCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PlayerController
    let paper: Paper

    private var isCurrent: Bool { store.playingPaperId == paper.id }
    private var position: Double {
        isCurrent && (player.currentTime > 0 || player.isPlaying) ? player.currentTime : paper.progress
    }
    private var length: Double {
        isCurrent && player.duration > 0 ? player.duration : paper.duration
    }
    private var fraction: Double { length > 0 ? min(1, max(0, position / length)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Episode", systemImage: "headphones",
                         trailing: length > 0 ? "\(Int((fraction * 100).rounded()))%" : nil)
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                Spacer()
                if isCurrent && player.turnCount > 0 && player.activeTurn >= 0 {
                    Text("Turn \(player.activeTurn + 1) of \(player.turnCount)")
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
                Text(formatT(position)).monospacedDigit()
                Spacer()
                Text(length > 0 ? "−" + formatT(max(0, length - position)) : "–:––").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if isCurrent, player.isRendering {
                Label("Preparing voices…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative)
            } else if isCurrent, let err = player.renderError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .glassCard()
    }

    private var headline: String {
        if length <= 0 { return paper.hasAudio ? "Ready to play" : "Script ready" }
        if paper.read && position <= 0.5 { return "Listened" }
        if position <= 0.5 { return "\(Int((length / 60).rounded())) min episode" }
        let left = max(0, length - position)
        return left < 60 ? "Almost done" : "\(Int((left / 60).rounded())) min left"
    }
}

// MARK: - Small pieces

private struct AuthorAvatar: View {
    let name: String

    private var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.stable(for: name).gradient, in: Circle())
    }
}

private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
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
        .help("Copy")
    }
}

/// Presents a paper's LaTeX (BibTeX) citation with a copy button.
private struct CitationView: View {
    let bibtex: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("LaTeX citation", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bibtex, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy citation", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

private struct ManageRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
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
    var onAdd: (String) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("tag", text: $text)
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
                    Label("Add tag", systemImage: "plus").font(.caption)
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

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { onAdd(t) }
        text = ""
    }
}
