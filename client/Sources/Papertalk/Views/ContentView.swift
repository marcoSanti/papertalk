import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showUpload = false
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(onUpload: { showUpload = true })
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            HStack(spacing: 0) {
                LibraryView()
                    .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 700)
                if showInspector {
                    Divider()
                    Group {
                        if let paper = store.selectedPaper() {
                            DetailView(paper: paper, onEdit: { store.editingPaper = paper })
                        } else {
                            EmptyDetailPlaceholder()
                        }
                    }
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showUpload = true
                } label: {
                    Label("Import paper", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.glassProminent)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                .help("Import a PDF paper")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Show or hide the paper inspector")
                Button {
                    store.settingsPage = .llm
                    store.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Open settings")
            }
        }
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
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: store.toast)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(player: store.player)
        }
        .onAppear {
            store.trackPlayback()
            Task { await store.loadAudioForSelected() }
        }
        .onChange(of: store.selectedId) { _ in
            // reveal the inspector automatically when a paper is selected
            if store.selectedPaper() != nil { showInspector = true }
            Task { await store.loadAudioForSelected() }
        }
    }
}

struct EmptyDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Select a paper").font(.title2)
            Text("Pick a paper from the library to see its details and audio.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}