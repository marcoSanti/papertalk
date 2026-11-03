// The main window's sidebar: the library sections, the user's libraries, the tags, and where
// the library lives.

#if os(macOS)
import SwiftUI

/// All Papers, Favorites, Authors, one row per library and one per tag, with counts; a native `List(selection:)`
/// (its highlight follows the system accent on purpose).
struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(selection: selection) {
            Section(L("Library")) {
                Label(L("All Papers"), systemImage: "books.vertical")
                    .badge(store.papers.count)
                    .tag(SidebarItem.all)
                Label(L("Favorites"), systemImage: "star")
                    .badge(store.favoritesCount)
                    .tag(SidebarItem.favorites)
                Label(L("Authors"), systemImage: "person.2")
                    .badge(store.authorCounts.count)
                    .help(L("Browse papers by author — like a contact book"))
                    .tag(SidebarItem.authors)
            }

            Section {
                if store.libraries.isEmpty {
                    Text(L("Create a library with + to sort papers into folders."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
                ForEach(store.libraries) { library in
                    Label {
                        HStack(spacing: 4) {
                            Text(library.name)
                            if let mark = LibraryPresentation.crossLinkMark(library) {
                                Image(systemName: mark.icon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(mark.help)
                            }
                        }
                    } icon: {
                        Image(systemName: library.icon)
                    }
                        .badge(store.sidebarCount(.library(library.id)))
                        .tag(SidebarItem.library(library.id))
                        .contextMenu {
                            Button(LibraryMapPresentation.open) { LibraryMapWindow.open(libraryId: library.id, store: store) }
                            Divider()
                            Button(L("Edit Library…")) { store.editingLibrary = LibraryForm(library) }
                            Button(L("Delete Library…"), role: .destructive) { store.requestDeleteLibrary(library.id) }
                        }
                }
            } header: {
                HStack {
                    Text(L("Libraries"))
                    Spacer()
                    Button {
                        store.editingLibrary = LibraryForm()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help(L("New Library…"))
                }
            }

            Section(L("Tags")) {
                if tagList.isEmpty {
                    Text(L("Add tags in a paper's Details and actions… to group papers here."))
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

    private var selection: Binding<SidebarItem?> {
        Binding(get: { store.sidebarSelection },
                set: { if let item = $0 { store.selectSidebar(item) } })
    }

    private var tagList: [(String, Int)] { store.tagCounts }

    // MARK: footer

    /// Where the library is stored: this Mac or a library server.
    private var footer: some View {
        HStack(spacing: 8) {
            let location = LibraryPresentation.storageLocation(isStandalone: store.isStandalone)
            Image(systemName: location.icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(location.title)
                    .font(.caption.weight(.medium))
                Text(L("Converted in-app"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.openSettings(.general)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(L("Settings (⌘,)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Opaque, so tags scrolled underneath don't show through.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

#endif
