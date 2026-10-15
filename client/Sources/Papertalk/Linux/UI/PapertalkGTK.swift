#if os(Linux)
import Foundation
import GtkBackend
import SwiftCrossUI

/// The Linux app: the shared AppStore behind a GTK 4 window (SwiftCrossUI).
@main
struct PapertalkGTK: App {
    typealias Backend = GtkBackend
    var backend: GtkBackend { GtkBackend(appIdentifier: "dev.papertalk.desktop") }

    @State var bridge = StoreBridge(AppStore())

    var body: some Scene {
        WindowGroup("Papertalk") {
            RootView(bridge: bridge)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("File") {
                Button("Import PDF…") { bridge.store.beginImport() }
                Button("Settings…") { bridge.store.settingsPage = .llm; bridge.store.showSettings = true }
            }
        }
    }
}

/// Sidebar | library | selected paper, with the player under the paper.
struct RootView: View {
    @State var bridge: StoreBridge

    var body: some View {
        let _ = bridge.revision
        // The split view must be the root, with no modifiers: inside a stack it
        // isn't given the window's height, and a modifier on it breaks its
        // layout. Presentations (alerts, sheets) go on inner views.
        NavigationSplitView {
            SidebarPane(bridge: bridge)
        } content: {
            LibraryPane(bridge: bridge)
        } detail: {
            VStack(spacing: 0) {
                DetailPane(bridge: bridge)
                Spacer()
                PlayerBar(bridge: bridge)
                    .alert(confirmationTitle, isPresented: confirmationShown) {
                        if let pending = bridge.store.pendingConfirmation {
                            Button(ConfirmationText(pending).confirmLabel) { bridge.store.confirmPending(pending) }
                        }
                        Button("Cancel") { bridge.store.pendingConfirmation = nil }
                    }
                    .alert(duplicateTitle, isPresented: duplicateShown) {
                        Button(duplicateText?.confirmLabel ?? "") { bridge.store.resolveDuplicate(true) }
                        Button("Cancel") { bridge.store.resolveDuplicate(false) }
                    }
                    .sheet(isPresented: bridge.binding(\.showUpload)) {
                        ImportSheet(bridge: bridge)
                    }
                    .sheet(isPresented: castShown) {
                        if let prompt = bridge.store.pendingCast {
                            CastSheet(bridge: bridge, prompt: prompt)
                        }
                    }
                    .sheet(isPresented: settingsShown) {
                        SettingsSheet(bridge: bridge, isSetup: bridge.store.showOnboarding)
                    }
            }
        }
    }

    private var confirmationTitle: String {
        bridge.store.pendingConfirmation.map { ConfirmationText($0).combined } ?? ""
    }

    private var duplicateText: ConfirmationText? {
        bridge.store.pendingDuplicate.map { ConfirmationText.duplicate(of: $0.duplicateOf) }
    }
    private var duplicateTitle: String { duplicateText?.combined ?? "" }
    private var duplicateShown: Binding<Bool> {
        Binding(get: { bridge.store.pendingDuplicate != nil },
                set: { if !$0 { bridge.store.resolveDuplicate(false) } })
    }
    /// Settings, or the first-launch setup (the same page).
    private var settingsShown: Binding<Bool> {
        Binding(get: { bridge.windowReady && (bridge.store.showSettings || bridge.store.showOnboarding) },
                set: { if !$0 { bridge.store.closeSettings() } })
    }
    private var castShown: Binding<Bool> {
        Binding(get: { bridge.store.pendingCast != nil },
                set: { if !$0 { bridge.store.cancelCast() } })
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { bridge.store.pendingConfirmation != nil },
                set: { if !$0 { bridge.store.pendingConfirmation = nil } })
    }
}
#endif
