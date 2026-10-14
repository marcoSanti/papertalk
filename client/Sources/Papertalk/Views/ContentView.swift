import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showUpload = false
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            HStack(spacing: 0) {
                LibraryView(onImport: { showUpload = true })
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        BottomBar(player: store.player)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    Divider()
                    inspectorContent
                        .frame(width: 340)
                }
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search papers (#tag to search tags)")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showUpload) {
            UploadSheet()
        }
        .sheet(item: $store.editingPaper) { paper in
            EditMetaSheet(paper: paper)
        }
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView()
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
        .onAppear {
            store.trackPlayback()
        }
        .onChange(of: store.selectedId) { _, _ in
            // reveal the inspector automatically when a paper is selected
            if store.selectedPaper() != nil {
                withAnimation(.snappy) { showInspector = true }
            }
        }
    }

    @ViewBuilder private var inspectorContent: some View {
        if let paper = store.selectedPaper() {
            DetailView(paper: paper, onEdit: { store.editingPaper = paper })
        } else {
            EmptyDetailPlaceholder()
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Layout", selection: $store.libraryLayout) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid)
                    .help("Grid")
                Image(systemName: "list.bullet").tag(LibraryLayout.list)
                    .help("List")
            }
            .pickerStyle(.segmented)
            .help("Change library layout")

            Menu {
                Picker("Sort by", selection: $store.sort) {
                    ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort papers")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                showUpload = true
            } label: {
                Label("Import", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .help("Import a PDF paper (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.snappy) { showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showInspector ? "Hide paper details" : "Show paper details")
        }
    }
}

extension SortOption {
    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .title: return "Title"
        case .recent: return "Recently converted"
        }
    }
}

struct EmptyDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("No paper selected", systemImage: "waveform.and.magnifyingglass")
        } description: {
            Text("Pick a paper from the library to see its details, tags and episode.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
