// How a paper looks in the library: its grid card, its cover (the PDF's first page, or a
// placeholder), its list row, and the context menu both share.

#if os(macOS)
import SwiftUI

// MARK: - Grid card

/// A paper in the cover grid: cover with status badge and progress strip, title and first author.
struct PaperCard: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    @State private var hovering = false

    private var isSelected: Bool { store.selectedId == paper.id }
    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
    }

    var body: some View {
        Button {
            store.selectedId = paper.id
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(isSelected ? Color.appAccent : Color.primary)
                    Text(PaperPresentation.cardSubtitle(paper))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { PaperWindow.present(paperId: paper.id, store: store) })
        .onHover { h in
            withAnimation(.snappy(duration: 0.2)) { hovering = h }
        }
        .contextMenu { ContextMenuItems(paper: paper) }
    }

    private var cover: some View {
        PaperArtwork(paper: paper)
            .overlay(alignment: .topLeading) { topLeadingBadge.padding(7) }
            .overlay(alignment: .topTrailing) {
                if paper.favorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .glassEffect(.regular, in: Circle())
                        .padding(7)
                }
            }
            .overlay(alignment: .bottom) { progressStrip }
            .clipShape(tileShape)
            .overlay {
                tileShape.strokeBorder(
                    isSelected ? Color.appAccent : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 3 : 0.5)
            }
            // Cast from a plain shape behind the cover: a shadow of the composited cover
            // (image, glass badges) is re-rendered on every scroll frame.
            .background {
                tileShape.fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(hovering || isSelected ? 0.24 : 0.12),
                            radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
            }
            .scaleEffect(hovering ? 1.025 : 1)
    }

    @ViewBuilder private var topLeadingBadge: some View {
        if PaperPresentation.showsStatusBadgeOnCover(paper) {
            StatusBadge(paper: paper, compact: true)
        } else if PaperPresentation.isNew(paper) {
            Text(L("NEW"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .glassEffect(.regular.tint(Color.appAccent), in: Capsule())
                .help(L("Not listened yet"))
        }
    }

    /// Conversion progress while running, otherwise listening progress.
    @ViewBuilder private var progressStrip: some View {
        let value = PaperPresentation.progressStrip(paper)
        if value > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.25))
                    Rectangle().fill(Color.appAccent)
                        .frame(width: geo.size.width * value)
                }
            }
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.25), value: value)
        }
    }
}

// MARK: - Artwork

/// First page of the paper as a "cover", at page aspect ratio. Falls back to a
/// soft gradient tile with a document glyph while loading / when there's no PDF.
/// The paper's cover: its PDF's first page, loaded once per `artworkRevision`, or a tinted
/// placeholder until it's there.
struct PaperArtwork: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(Theme.pageAspect, contentMode: .fit)
            .overlay {
                // A card scrolled back into view shows its cached cover at once, not the placeholder.
                if let image = image ?? store.cachedThumbnail(paper.id) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: "\(paper.id)|\(paper.hasPdf)|\(store.artworkRevision[paper.id] ?? 0)") {
                guard paper.hasPdf else { image = nil; return }
                let loaded = await store.loadThumbnail(paper.id)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.appAccent.opacity(0.35), Color.indigo.opacity(0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "doc.richtext")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Context menu

/// Context menu shared by the grid card and list row.
/// The right-click menu of a paper (grid and list): play, open, favourite, listened, rerun,
/// audio and delete actions.
struct ContextMenuItems: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    var body: some View {
        Button {
            store.selectedId = paper.id
            PaperWindow.present(paperId: paper.id, store: store)
        } label: {
            Label(L("Open"), systemImage: "arrow.up.forward.app")
        }
        let play = PaperPresentation.playButton(paper, isPlaying: store.playingPaperId == paper.id && store.player.isPlaying)
        Button {
            store.togglePlayback(paper.id)
        } label: {
            Label(play.title, systemImage: play.icon)
        }
        .disabled(!PaperPresentation.isPlayable(paper))
        Button {
            PaperPanels.openPDF(paper, from: store)
        } label: {
            Label(L("PDF"), systemImage: "doc.text")
        }
        .disabled(!paper.hasPdf)
        Button {
            store.showTranscript(paper.id)
        } label: {
            Label(L("Transcript"), systemImage: "text.quote")
        }
        .disabled(!paper.hasScript)
        Button {
            MindMapWindow.open(paperId: paper.id, store: store)
        } label: {
            Label(L("Mind map"), systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(!PaperPresentation.hasMindMap(paper))
        Divider()
        let favorite = PaperPresentation.favoriteToggle(paper)
        Button {
            store.toggleFavorite(paper.id)
        } label: {
            Label(favorite.title, systemImage: favorite.icon)
        }
        Button {
            store.toggleRead(paper.id)
        } label: {
            Label(PaperPresentation.listenedToggle(paper).title, systemImage: "checkmark.circle")
        }
        if !store.libraries.isEmpty {
            Picker(selection: Binding(get: { paper.library }, set: { store.moveToLibrary(paper.id, $0) })) {
                Text(L("No Library")).tag(String?.none)
                ForEach(store.libraries) { library in
                    Label(library.name, systemImage: library.icon).tag(Optional(library.id))
                }
            } label: {
                Label(L("Move to Library"), systemImage: "folder")
            }
            .pickerStyle(.menu)
        }
        Divider()
        Button {
            store.editingPaper = paper
        } label: {
            Label(L("Edit metadata…"), systemImage: "pencil")
        }
        Button {
            store.requestRerun(paper)
        } label: {
            Label(L("Rerun episode"), systemImage: "arrow.counterclockwise")
        }
        .disabled(!PaperPresentation.canRerun(paper))
        if PaperPresentation.canStop(paper) {
            Button {
                store.stopConversion(paper.id)
            } label: {
                Label(PaperPresentation.stopTitle, systemImage: "stop.circle")
            }
        }
        Button {
            store.createMindMap(paper.id)
        } label: {
            Label(PaperPresentation.mindMapRow(paper, drawing: store.drawingMindMaps.contains(paper.id)).title,
                  systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(!store.canCreateMindMap(paper))
        Button {
            store.refreshMeta(paper.id)
        } label: {
            Label(L("Refresh metadata"), systemImage: "arrow.clockwise")
        }
        Button {
            store.regenerateAudio(paper.id)
        } label: {
            Label(L("Regenerate audio"), systemImage: "waveform.badge.magnifyingglass")
        }
        .disabled(!PaperPresentation.canRegenerateAudio(paper, anyConversionRunning: store.activeRun != nil))
        Button {
            PaperPanels.exportAudio(paper, from: store)
        } label: {
            Label(L("Export audio…"), systemImage: "square.and.arrow.up")
        }
        .disabled(!EpisodeExport.canExport(paper))
        Button {
            PaperPanels.exportPaper(paper, from: store)
        } label: {
            Label(L("Export paper…"), systemImage: "shippingbox")
        }
        .disabled(!PaperPresentation.canExportPaper(paper))
        if store.isStandalone {
            Button {
                store.revealInFinder(paper.id)
            } label: {
                Label(L("Show in Finder"), systemImage: "folder")
            }
        }
        Divider()
        if PaperPresentation.canDeleteAudio(paper) {
            Button(role: .destructive) {
                store.pendingConfirmation = .deleteAudio(paper)
            } label: {
                Label(L("Delete audio…"), systemImage: "waveform.slash")
            }
        }
        Button(role: .destructive) {
            store.pendingConfirmation = .delete(paper)
        } label: {
            Label(L("Delete"), systemImage: "trash")
        }
    }
}

// MARK: - List row

/// Compact row for the list layout (lives inside a native `List`, which owns
/// selection highlighting and keyboard navigation).
/// A paper in the list layout: small cover, title, authors and status.
struct PaperListRow: View {
    let paper: Paper

    var body: some View {
        HStack(spacing: 12) {
            PaperArtwork(paper: paper)
                .frame(width: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if PaperPresentation.isNew(paper) {
                        Circle().fill(Color.appAccent).frame(width: 7, height: 7)
                            .help(L("Not listened yet"))
                    }
                    Text(paper.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                Text(PaperPresentation.listSubtitle(paper))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let d = paper.depthTitle {
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
            if paper.favorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            StatusBadge(paper: paper, compact: true)
            if let date = PaperPresentation.publishedDate(paper) {
                Text(date)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}

#endif
