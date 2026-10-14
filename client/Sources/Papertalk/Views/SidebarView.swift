import SwiftUI

/// What the sidebar can point the library at.
enum SidebarItem: Hashable {
    case all, favorites, tag(String)
}

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("All Papers", systemImage: "books.vertical")
                    .badge(store.papers.count)
                    .tag(SidebarItem.all)
                Label("Favorites", systemImage: "star")
                    .badge(favoritesCount)
                    .tag(SidebarItem.favorites)
            }

            Section("Tags") {
                if tagList.isEmpty {
                    Text("Add tags in the inspector to group papers here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                } else {
                    ForEach(tagList, id: \.0) { tag, count in
                        Label(tag, systemImage: "number")
                            .badge(count)
                            .tag(SidebarItem.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    // MARK: selection <-> store

    private var current: SidebarItem {
        switch store.view {
        case .all: return .all
        case .fav: return .favorites
        case .tag: return store.activeTag.map { SidebarItem.tag($0) } ?? .all
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { current },
            set: { item in
                guard let item, item != current else { return }
                switch item {
                case .all:
                    store.view = .all; store.activeTag = nil
                case .favorites:
                    store.view = .fav; store.activeTag = nil
                case .tag(let t):
                    store.view = .tag; store.activeTag = t
                }
                // Keep the inspector on the current paper if it's still in scope.
                if let id = store.selectedId, !store.filteredPapers().contains(where: { $0.id == id }) {
                    store.selectedId = nil
                }
            }
        )
    }

    private var tagList: [(String, Int)] { store.tagCounts }
    private var favoritesCount: Int { store.papers.values.filter { $0.favorite }.count }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isStandalone ? "desktopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.isStandalone ? "On this Mac" : "Library server")
                    .font(.caption.weight(.medium))
                Text("Converted in-app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.settingsPage = .llm
                store.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
