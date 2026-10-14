import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    var onImport: () -> Void = {}

    @Namespace private var filterNS

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
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .background(AmbientBackground())
        .navigationTitle(title)
        .navigationSubtitle(subtitle(papers.count))
    }

    // MARK: titles

    private var title: String {
        switch store.view {
        case .all: return "All Papers"
        case .fav: return "Favorites"
        case .tag: return store.activeTag.map { "#\($0)" } ?? "Tag"
        }
    }

    private func subtitle(_ n: Int) -> String {
        n == 1 ? "1 paper" : "\(n) papers"
    }

    // MARK: status filter bar (floating glass)

    private struct StatusFilter: Identifiable {
        let value: String, title: String, icon: String
        var id: String { value }
    }

    private let filters: [StatusFilter] = [
        .init(value: "all", title: "All", icon: "square.stack"),
        .init(value: "running", title: "Converting", icon: "hourglass"),
        .init(value: "done", title: "Ready", icon: "waveform"),
        .init(value: "error", title: "Failed", icon: "exclamationmark.triangle"),
    ]

    private var filterBar: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(filters) { f in filterButton(f) }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func filterButton(_ f: StatusFilter) -> some View {
        let selected = store.statusFilter == f.value
        let n = count(for: f.value)
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

    /// Papers in the current sidebar scope with the given state (ignores search).
    private func count(for value: String) -> Int {
        let scoped = store.papers.values.filter { p in
            switch store.view {
            case .all: return true
            case .fav: return p.favorite
            case .tag: return store.activeTag.map { p.tags.contains($0) } ?? true
            }
        }
        return value == "all" ? scoped.count : scoped.filter { $0.state == value }.count
    }

    // MARK: layouts

    private func grid(_ papers: [Paper]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 22, alignment: .top)]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(papers) { paper in
                    PaperCard(paper: paper)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
    }

    private func list(_ papers: [Paper]) -> some View {
        List(papers, selection: $store.selectedId) { paper in
            PaperListRow(paper: paper)
                .contextMenu { ContextMenuItems(paper: paper) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: empty states

    @ViewBuilder private var emptyState: some View {
        if store.papers.isEmpty {
            ContentUnavailableView {
                Label("Your library is empty", systemImage: "doc.badge.plus")
            } description: {
                Text("Import a PDF and Papertalk will turn it into a podcast episode, right on this Mac.")
            } actions: {
                Button("Import a paper…", action: onImport)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        } else if !store.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: store.search)
        } else {
            ContentUnavailableView {
                Label("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No papers match the current filters.")
            } actions: {
                Button("Show all papers") {
                    withAnimation(.snappy) { store.statusFilter = "all" }
                }
                .buttonStyle(.glass)
            }
        }
    }
}
