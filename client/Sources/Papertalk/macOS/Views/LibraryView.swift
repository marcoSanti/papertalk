// The library: the papers in the current scope as a cover grid or a list, with status filters,
// keyboard navigation, drop-to-import, and empty states.

#if os(macOS)
import SwiftUI

/// The middle column of the main window.
struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    /// Opens the import sheet (from the empty state's button).
    var onImport: () -> Void = {}

    @Namespace private var filterNS
    @FocusState private var libraryFocused: Bool
    @State private var gridWidth: CGFloat = 0
    @State private var dropTargeted = false

    var body: some View {
        let papers = store.filteredPapers()
        Group {
            if papers.isEmpty {
                emptyState
            } else if store.libraryLayout == .grid {
                grid(papers)
            } else {
                list(papers)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($libraryFocused)
        .onKeyPress(.space) { store.playSelected() ? .handled : .ignored }
        .onKeyPress(.return) { store.playSelected() ? .handled : .ignored }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            store.requestDeleteSelected() ? .handled : .ignored
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            // The native List handles its own arrows; this drives the grid.
            guard store.libraryLayout == .grid else { return .ignored }
            let move: LibraryPresentation.Move = switch press.key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            default: .down
            }
            let columns = LibraryPresentation.gridColumns(width: gridWidth)
            return store.moveSelection(move, in: papers, columns: columns) ? .handled : .ignored
        }
        .onChange(of: store.selectedId) { _, id in
            if id != nil { libraryFocused = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.openFiles(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.appAccent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Color.appAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        Label(L("Drop a PDF or a Papertalk paper to import it"), systemImage: "arrow.down.doc")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if store.view == .author, let name = store.activeAuthor {
                    AuthorHeader(name: name)
                }
                filterBar
            }
        }
        .background(AmbientBackground())
        .navigationTitle(LibraryPresentation.title(view: store.view, tag: store.activeTag, author: store.activeAuthor))
        .navigationSubtitle(LibraryPresentation.paperCount(papers.count))
        .toolbar {
            if store.view == .author {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            store.view = .authors; store.activeAuthor = nil
                        }
                    } label: {
                        Label(L("All authors"), systemImage: "chevron.left")
                    }
                    .help(L("Back to all authors"))
                }
            }
        }
    }

    // MARK: status filter bar (floating glass)

    /// The status filter capsules (All, Converting, Ready, Failed) with their counts.
    private var filterBar: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(LibraryPresentation.statusFilters) { f in filterButton(f) }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// One filter capsule; the selected one slides under it.
    private func filterButton(_ f: LibraryPresentation.StatusFilter) -> some View {
        let selected = store.statusFilter == f.value
        let n = store.count(status: f.value)
        return Button {
            withAnimation(.snappy(duration: 0.25)) { store.statusFilter = f.value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: f.icon).imageScale(.small)
                Text(f.title)
                if n > 0 {
                    Text("\(n)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.appAccent.gradient)
                        .matchedGeometryEffect(id: "selection", in: filterNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: layouts

    /// Cover cards on an adaptive grid (its columns match `LibraryPresentation.gridColumns`).
    private func grid(_ papers: [Paper]) -> some View {
        typealias G = LibraryPresentation.Grid
        let columns = [GridItem(.adaptive(minimum: G.minTile, maximum: G.maxTile), spacing: G.spacing, alignment: .top)]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(papers) { paper in
                    PaperCard(paper: paper)
                }
            }
            .padding(.horizontal, G.sidePadding)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    /// Compact rows.
    private func list(_ papers: [Paper]) -> some View {
        List(papers, selection: $store.selectedId) { paper in
            PaperListRow(paper: paper)
                .contextMenu { ContextMenuItems(paper: paper) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: empty states

    /// An empty library, a search with no results, or filters that hide everything.
    @ViewBuilder private var emptyState: some View {
        switch LibraryPresentation.emptyState(libraryIsEmpty: store.papers.isEmpty, search: store.search) {
        case .emptyLibrary:
            ContentUnavailableView {
                Label(L("Your library is empty"), systemImage: "doc.badge.plus")
            } description: {
                Text(L("Import a PDF and Papertalk will turn it into a podcast episode, right on this Mac."))
            } actions: {
                Button(L("Import a paper…"), action: onImport)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        case .noSearchResults(let text):
            ContentUnavailableView.search(text: text)
        case .filteredOut:
            ContentUnavailableView {
                Label(L("Nothing here"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(L("No papers match the current filters."))
            } actions: {
                Button(L("Show all papers")) {
                    withAnimation(.snappy) { store.statusFilter = "all" }
                }
                .buttonStyle(.glass)
            }
        }
    }
}

#endif
