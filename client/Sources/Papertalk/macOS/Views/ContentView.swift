// The main window: sidebar, library and details panel, the toolbar, and every sheet, dialog,
// alert and toast the store asks for.

#if os(macOS)
import SwiftUI

/// The window's root. Sheets and confirmations are presented from here, once, driven by the
/// store's state (a dialog attached inside a context menu would vanish with the menu).
struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("papertalk.showInspector") private var showInspector = true
    @AppStorage("papertalk.inspectorWidth") private var inspectorWidth: Double = InspectorLayout.defaultWidth

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if store.view == .authors, store.activeAuthor == nil {
                        AuthorsView()
                    } else {
                        LibraryView(onImport: { store.beginImport() })
                    }
                }
                // The player stays put while browsing authors too.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    BottomBar(player: store.player)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    InspectorResizeHandle(width: $inspectorWidth)
                    inspectorContent
                        .frame(width: inspectorWidth)
                }
            }
        }
        // Rebuilt in a new language, so views that don't watch the store redraw too.
        .id(store.language)
        .searchable(text: $store.search, placement: .toolbar, prompt: L("Search titles, authors, DOI (#tag for tags)"))
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
        .sheet(isPresented: castShown) {
            if let p = store.pendingCast {
                CastSheet(paperTitle: p.paperTitle, proposals: p.proposals, authors: p.authors, authorGenders: p.authorGenders)
            }
        }
        .sheet(item: $store.transcriptSheet) { TranscriptSheetView(item: $0) }
        .confirmationDialog(store.pendingConfirmation.map { ConfirmationText($0).title } ?? "",
                            isPresented: confirmationShown,
                            titleVisibility: .visible, presenting: store.pendingConfirmation) { pending in
            let text = ConfirmationText(pending)
            Button(text.confirmLabel, role: .destructive) { store.confirmPending(pending) }
            if let secondary = text.secondaryLabel {
                Button(secondary) { store.confirmSecondary(pending) }
            }
            Button(text.cancelLabel, role: .cancel) {}
        } message: { pending in
            Text(ConfirmationText(pending).message)
        }
        .confirmationDialog(duplicateText?.title ?? "", isPresented: duplicateShown,
                            titleVisibility: .visible) {
            Button(duplicateText?.confirmLabel ?? "") { store.resolveDuplicate(true) }
            Button(L("Cancel"), role: .cancel) { store.resolveDuplicate(false) }
        } message: {
            if let message = duplicateText?.message { Text(message) }
        }
        .alert(store.updateAlert?.title ?? "", isPresented: updateAlertShown,
               presenting: store.updateAlert) { alert in
            if let label = alert.actionLabel {
                Button(label) { store.openUpdateLink(alert) }
                Button(L("Not Now"), role: .cancel) {}
            } else {
                Button(L("OK"), role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
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
            NowPlaying.shared.attach(to: store)
        }
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { store.pendingConfirmation != nil },
                set: { if !$0 { store.pendingConfirmation = nil } })
    }

    private var updateAlertShown: Binding<Bool> {
        Binding(get: { store.updateAlert != nil },
                set: { if !$0 { store.updateAlert = nil } })
    }

    private var duplicateText: ConfirmationText? {
        store.pendingDuplicate.map { ConfirmationText.duplicate(of: $0.duplicateOf) }
    }
    private var duplicateShown: Binding<Bool> {
        Binding(get: { store.pendingDuplicate != nil },
                set: { if !$0 { store.resolveDuplicate(false) } })
    }
    private var castShown: Binding<Bool> {
        Binding(get: { store.pendingCast != nil },
                set: { if !$0 { store.cancelCast() } })
    }

    /// The selected paper's details, or a placeholder.
    @ViewBuilder private var inspectorContent: some View {
        if let paper = store.selectedPaper() {
            DetailView(paper: paper, onEdit: { store.editingPaper = paper })
        } else {
            EmptyDetailPlaceholder()
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(L("Layout"), selection: $store.libraryLayout) {
                Label(L("Grid"), systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                Label(L("List"), systemImage: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help(L("Change library layout"))

            Menu {
                Picker(L("Sort by"), selection: $store.sort) {
                    ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(L("Sort"), systemImage: "arrow.up.arrow.down")
            }
            .help(L("Sort papers"))
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.beginImport()
            } label: {
                Label(L("Import"), systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .help(L("Import a PDF paper (⌘O)"))
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.snappy) { showInspector.toggle() }
            } label: {
                Label(L("Inspector"), systemImage: "sidebar.trailing")
            }
            .help(showInspector ? L("Hide paper details") : L("Show paper details"))
        }
    }
}

/// The details panel with nothing selected.
struct EmptyDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label(L("No paper selected"), systemImage: "waveform.and.magnifyingglass")
        } description: {
            Text(L("Pick a paper from the library to see its details, tags and episode."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Divider between library and inspector that can be dragged to resize the inspector.
private struct InspectorResizeHandle: View {
    @Binding var width: Double
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
                                width = InspectorLayout.width(startingAt: start, dragged: g.translation.width)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .help(L("Drag to resize"))
    }
}

#endif
