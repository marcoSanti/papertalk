import SwiftUI

struct PaperCard: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    private var isSelected: Bool { store.selectedId == paper.id }
    private var progressFraction: Double {
        paper.duration > 0 && paper.progress > 0 ? min(1, paper.progress / paper.duration) : 0
    }

    var body: some View {
        Button {
            store.selectedId = paper.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                coverBox
                VStack(alignment: .leading, spacing: 3) {
                    Text(paper.displayTitle)
                        .font(.callout).fontWeight(.semibold)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let depth = paper.depthTitle {
                        Text(depth).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isSelected ? 0.08 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.appAccent : Color.clear, lineWidth: 1.5)
        )
        .contextMenu { ContextMenuItems(paper: paper) }
    }

    private var coverBox: some View {
        ZStack {
            if paper.hasPdf {
                PDFThumb(id: paper.id, height: 120)
            } else {
                placeholder
            }
            if paper.state == "error" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22)).foregroundStyle(.red)
            } else if paper.isActive {
                ProgressView().controlSize(.regular).tint(.white)
                    .padding(8).background(.black.opacity(0.5), in: Circle())
            } else if !paper.read && paper.isDone {
                Text("NEW").font(.caption2).bold().foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.appAccent, in: Capsule())
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
            if progressFraction > 0 && !paper.isActive {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.35)
                            Color.appAccent.frame(width: geo.size.width * progressFraction)
                        }.frame(height: 4)
                    }
                }
            }
        }
        .frame(height: 120)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.25)).frame(height: 120)
            .overlay(Image(systemName: "doc.richtext").font(.system(size: 26)).foregroundStyle(.secondary))
    }
}

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
        Button {
            store.toggleFavorite(paper.id)
        } label: {
            Label(paper.favorite ? "Remove from favorites" : "Add to favorites",
                  systemImage: paper.favorite ? "star.fill" : "star")
        }
        Button {
            store.toggleRead(paper.id)
        } label: {
            Label(paper.read ? "Mark as unread" : "Mark as read", systemImage: "checkmark.circle")
        }
        Divider()
        Button {
            store.editingPaper = paper
        } label: {
            Label("Edit metadata…", systemImage: "pencil")
        }
        Button {
            store.rerun(paper.id)
        } label: {
            Label("Rerun episode", systemImage: "arrow.counterclockwise")
        }
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
            store.delete(paper.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Renders a paper's first-page PDF thumbnail (aspect-fit inside a fixed-height,
/// rounded box) asynchronously, falling back to a generic placeholder.
struct PDFThumb: View {
    @EnvironmentObject private var store: AppStore
    let id: String
    var height: CGFloat = 120

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.25)).frame(height: height)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .scaledToFill()
                    .frame(width: .infinity, height: height)
                    .clipped()
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "doc.richtext").font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: id) {
            guard image == nil else { return }
            image = await store.loadThumbnail(id)
        }
    }
}

/// Compact single-row paper row for the list layout.
struct PaperListRow: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper

    private var isSelected: Bool { store.selectedId == paper.id }

    var body: some View {
        Button {
            store.selectedId = paper.id
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                        .frame(width: 40, height: 56)
                    if paper.hasPdf {
                        PDFThumb(id: paper.id, height: 56)
                            .frame(width: 40)
                    } else {
                        Image(systemName: "doc.richtext").font(.system(size: 18)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(paper.displayTitle).font(.callout).fontWeight(.medium)
                        .lineLimit(1)
                    if !paper.authors.isEmpty {
                        Text(paper.authors.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let d = paper.depthTitle {
                            Text(d).font(.caption2).foregroundStyle(.secondary)
                        }
                        if paper.isDone {
                            Text("Done").font(.caption2).foregroundStyle(.green)
                        } else if paper.isActive {
                            Text("Running…").font(.caption2).foregroundStyle(Color.appAccent)
                        } else if paper.state == "error" {
                            Text("Error").font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
                Spacer()
                if paper.favorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.primary.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.appAccent : Color.clear, lineWidth: 1.5))
        .contextMenu {
            ContextMenuItems(paper: paper)
        }
    }
}