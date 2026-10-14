import SwiftUI

// MARK: - Grid card

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
            .shadow(color: .black.opacity(hovering || isSelected ? 0.24 : 0.12),
                    radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
            .scaleEffect(hovering ? 1.025 : 1)
    }

    @ViewBuilder private var topLeadingBadge: some View {
        if PaperPresentation.showsStatusBadgeOnCover(paper) {
            StatusBadge(paper: paper, compact: true)
        } else if PaperPresentation.isNew(paper) {
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .glassEffect(.regular.tint(Color.appAccent), in: Capsule())
                .help("Not listened yet")
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
struct PaperArtwork: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(Theme.pageAspect, contentMode: .fit)
            .overlay {
                if let image {
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
struct ContextMenuItems: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    var body: some View {
        Button {
            store.selectedId = paper.id
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
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
        Divider()
        Button {
            store.editingPaper = paper
        } label: {
            Label("Edit metadata…", systemImage: "pencil")
        }
        Button {
            store.requestRerun(paper)
        } label: {
            Label("Rerun episode", systemImage: "arrow.counterclockwise")
        }
        .disabled(!PaperPresentation.canRerun(paper))
        Button {
            store.refreshMeta(paper.id)
        } label: {
            Label("Refresh metadata", systemImage: "arrow.clockwise")
        }
        if store.isStandalone {
            Button {
                store.revealInFinder(paper.id)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) {
            store.pendingConfirmation = .delete(paper)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - List row

/// Compact row for the list layout (lives inside a native `List`, which owns
/// selection highlighting and keyboard navigation).
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
                            .help("Not listened yet")
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
