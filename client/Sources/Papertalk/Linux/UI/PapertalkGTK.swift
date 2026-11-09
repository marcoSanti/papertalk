// The Linux app's entry point (SwiftCrossUI on GTK 4) and its root view.

#if os(Linux)
import Foundation
import GtkBackend
import SwiftCrossUI

/// The Linux app: the shared AppStore behind a GTK 4 window (SwiftCrossUI).
/// One window over one `AppStore`, created in the saved interface language.
@main
struct PapertalkGTK: App {
    typealias Backend = GtkBackend
    var backend: GtkBackend { GtkBackend(appIdentifier: "dev.papertalk.desktop") }

    @State var bridge = StoreBridge(AppStore.launch())

    var body: some Scene {
        WindowGroup("Papertalk") {
            RootView(bridge: bridge)
        }
        .defaultSize(width: 1180, height: 740)
        // The GTK backend always draws its light scheme and ignores `preferredColorScheme`,
        // so the desktop's preference is set on the scene: every pane and sheet follows it.
        .environment(\.colorScheme, bridge.colorScheme)
        .commands {
            CommandMenu(L("File")) {
                Button(L("Import PDF…")) { bridge.store.beginImport() }
                Button(L("Settings…")) { bridge.store.openSettings(.llm) }
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
                        // As on macOS: confirm, an optional third choice, and the cancel wording.
                        if let pending = bridge.store.pendingConfirmation {
                            let text = ConfirmationText(pending)
                            Button(text.confirmLabel) { bridge.store.confirmPending(pending) }
                            if let secondary = text.secondaryLabel {
                                Button(secondary) { bridge.store.confirmSecondary(pending) }
                            }
                            Button(text.cancelLabel) { bridge.store.pendingConfirmation = nil }
                        }
                    }
                    .alert(duplicateTitle, isPresented: duplicateShown) {
                        Button(duplicateText?.confirmLabel ?? "") { bridge.store.resolveDuplicate(true) }
                        Button(L("Cancel")) { bridge.store.resolveDuplicate(false) }
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

    private var confirmationTitle: String { ConfirmationText.combinedTitle(bridge.store.pendingConfirmation) }

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
