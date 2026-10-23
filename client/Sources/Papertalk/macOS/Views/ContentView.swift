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
                    if store.showsAuthorIndex {
                        AuthorsView()
                    } else {
                        LibraryView(onImport: { store.beginImport() })
                    }
                }
                // The toolbar has no background of its own (so none runs over the panel): this
                // stands in for it over the library, so scrolled papers don't show under its buttons.
                .overlay(alignment: .top) {
                    GeometryReader { g in
                        Rectangle().fill(.bar)
                            .frame(height: g.safeAreaInsets.top)
                            .ignoresSafeArea(edges: .top)
                    }
                    .allowsHitTesting(false)
                }
                // The player stays put while browsing authors too.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    BottomBar(player: store.player)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Always in the layout, its width animated: inserted and removed, it popped in and out.
                HStack(spacing: 0) {
                    InspectorResizeHandle(width: $inspectorWidth)
                    inspectorContent
                        .frame(width: inspectorWidth)
                        // No toolbar above it, so no dark band where one would be.
                        .scrollEdgeEffectHidden(true, for: .top)
                }
                // Up to the window's top: the toolbar keeps clear of the panel (see `toolbarContent`).
                .ignoresSafeArea(.container, edges: .top)
                .frame(width: showInspector ? inspectorWidth + 1 : 0, alignment: .leading)
                // Not `.clipped()`: that also cut off the backdrop running up under the toolbar.
                .mask(Rectangle().ignoresSafeArea())
                .opacity(showInspector ? 1 : 0)
                .allowsHitTesting(showInspector)
            }
            // On the whole row, so the library resizes with the panel. Explicit, because
            // `withAnimation` around an `@AppStorage` toggle didn't animate.
            .animation(.smooth(duration: 0.5), value: showInspector)
        }
        // Rebuilt in a new language, so views that don't watch the store redraw too.
        .id(store.language)
        .toolbar { toolbarContent }
        // The toolbar's own background ran across the panel as a dark band; the library draws
        // its own instead.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $store.showUpload) {
            UploadSheet()
        }
        .sheet(item: $store.editingPaper) { paper in
            EditMetaSheet(paper: paper)
        }
        .sheet(item: $store.editingLibrary) { LibrarySheet(form: $0) }
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
                showInspector.toggle()
            } label: {
                Label(L("Inspector"), systemImage: "sidebar.trailing")
            }
            .help(showInspector ? L("Hide paper details") : L("Show paper details"))
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Not `.searchable`: that field always sits at the toolbar's far end, over the panel.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search titles, authors, DOI (#tag for tags)"), text: $store.search)
                    .textFieldStyle(.plain)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .frame(width: InspectorLayout.searchWidth, height: 36)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        // Its own capsule: in the shared one it pulled the panel button in with it.
        .sharedBackgroundVisibility(.hidden)

        // Keeps the toolbar clear of the panel, so above it there's only the panel. Added and
        // removed (and re-made on resize) because the toolbar doesn't re-measure a changed width.
        if showInspector {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: inspectorWidth, height: 1).id(inspectorWidth)
            }
            .sharedBackgroundVisibility(.hidden)
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
