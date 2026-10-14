import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            statusPills
            Divider()
            if store.filteredPapers().isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.libraryLayout == .grid {
                grid
            } else {
                list
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Library")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            searchField
            Picker("Sort", selection: $store.sort) {
                ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 170)
            Picker("Layout", selection: $store.libraryLayout) {
                ForEach(LibraryLayout.allCases) {
                    Image(systemName: $0 == .grid ? "square.grid.2x2" : "list.bullet").tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 72)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search title, filename, tags…", text: $store.search)
                .textFieldStyle(.plain)
            if !store.search.isEmpty {
                Button {
                    store.search = ""
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private var statusPills: some View {
        HStack(spacing: 6) {
            pill("All", "all")
            pill("Running", "running")
            pill("Done", "done")
            pill("Error", "error")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func pill(_ label: String, _ value: String) -> some View {
        Button {
            store.statusFilter = value
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(store.statusFilter == value ? Color.appAccent : Color.clear, in: Capsule())
                .foregroundStyle(store.statusFilter == value ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(store.filteredPapers()) { paper in
                    PaperCard(paper: paper)
                }
            }
            .padding(16)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(store.filteredPapers()) { paper in
                    PaperListRow(paper: paper)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if store.papers.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Your library is empty").font(.title3)
                Text("Upload a PDF to start converting it into a podcast.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("No results").font(.title3)
                Text("Nothing matches your current filters.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}