#if os(macOS)
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("All Papers", systemImage: "books.vertical")
                    .badge(store.papers.count)
                    .tag(SidebarItem.all)
                Label("Favorites", systemImage: "star")
                    .badge(store.favoritesCount)
                    .tag(SidebarItem.favorites)
                Label("Authors", systemImage: "person.2")
                    .badge(store.authorCounts.count)
                    .help("Browse papers by author — like a contact book")
                    .tag(SidebarItem.authors)
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

    private var selection: Binding<SidebarItem?> {
        Binding(get: { store.sidebarSelection },
                set: { if let item = $0 { store.selectSidebar(item) } })
    }

    private var tagList: [(String, Int)] { store.tagCounts }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            let location = LibraryPresentation.storageLocation(isStandalone: store.isStandalone)
            Image(systemName: location.icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(location.title)
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

#endif
