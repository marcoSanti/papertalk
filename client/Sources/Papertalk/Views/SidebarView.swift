import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    var onUpload: () -> Void

    var body: some View {
        List(selection: $store.selectedId) {
            Section {
                Button(action: onUpload) {
                    Label("Import paper", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glassProminent)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                .padding(.vertical, 2)
            }

            Section {
                navButton("All papers", icon: "doc.text", view: .all) { store.papers.count }
                navButton("Favorites", icon: "star", view: .fav) {
                    store.papers.values.filter { $0.favorite }.count
                }
            }

            if !tagList.isEmpty {
                Section("Tags") {
                    ForEach(tagList, id: \.0) { tag, count in
                        Button {
                            store.view = .tag
                            store.activeTag = tag
                            store.selectedId = nil
                        } label: {
                            HStack {
                                Label("#\(tag)", systemImage: "tag")
                                Spacer()
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(store.view == .tag && store.activeTag == tag ? Color.accentColor : .primary)
                        .fontWeight(store.view == .tag && store.activeTag == tag ? .semibold : .regular)
                    }
                }
            } else {
                Section("Tags") {
                    Text("No tags yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Papertalk")
        .navigationSubtitle(headerNote)
        .overlay(alignment: .bottom) {
            Text("Local conversion")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
    }

    private var tagList: [(String, Int)] { store.tagCounts }

    private var headerNote: String {
        "Converted in-app"
    }

    @ViewBuilder
    private func navButton(_ title: String, icon: String, view: AppStore.ViewMode, count: @escaping () -> Int) -> some View {
        Button {
            store.view = view
            store.activeTag = nil
            store.selectedId = nil
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(count())")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(store.view == view && store.activeTag == nil ? Color.accentColor : .primary)
        .fontWeight(store.view == view && store.activeTag == nil ? .semibold : .regular)
    }
}