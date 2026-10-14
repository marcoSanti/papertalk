import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("papertalk.showInspector") private var showInspector = true
    @AppStorage("papertalk.inspectorWidth") private var inspectorWidth: Double = 340

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            HStack(spacing: 0) {
                LibraryView(onImport: { store.beginImport() })
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        BottomBar(player: store.player)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    InspectorResizeHandle(width: $inspectorWidth, range: 300...520)
                    inspectorContent
                        .frame(width: inspectorWidth)
                }
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search titles, authors, DOI (#tag for tags)")
        .toolbar { toolbarContent }
        .sheet(isPresented: $store.showUpload) {
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
                .interactiveDismissDisabled()
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationShown,
                            titleVisibility: .visible, presenting: store.pendingConfirmation) { pending in
            switch pending {
            case .delete(let p):
                Button("Delete paper", role: .destructive) { store.delete(p.id) }
            case .rerun(let p):
                Button("Rerun episode", role: .destructive) { store.rerun(p.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            switch pending {
            case .delete:
                Text("The PDF, transcript and generated audio are removed from the library. This can’t be undone.")
            case .rerun:
                Text("The current script and audio are replaced with a newly written episode.")
            }
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
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { store.pendingConfirmation != nil },
                set: { if !$0 { store.pendingConfirmation = nil } })
    }

    private var confirmationTitle: String {
        switch store.pendingConfirmation {
        case .delete(let p): return "Delete “\(p.displayTitle)”?"
        case .rerun(let p): return "Rerun “\(p.displayTitle)”?"
        case nil: return ""
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
                Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
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
                store.beginImport()
            } label: {
                Label("Import", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .help("Import a PDF paper (⌘O)")
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

/// Divider between library and inspector that can be dragged to resize the inspector.
private struct InspectorResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let start = startWidth ?? width
                                startWidth = start
                                // Dragging left widens the trailing inspector.
                                width = min(range.upperBound, max(range.lowerBound, start - g.translation.width))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .help("Drag to resize")
    }
}
