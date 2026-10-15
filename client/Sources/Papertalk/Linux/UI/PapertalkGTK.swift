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
        _ = bridge.revision
        // The split view must be the root: inside a stack it isn't given the
        // window's height and its panes overflow. The player sits under the detail.
        return NavigationSplitView {
            SidebarPane(bridge: bridge)
        } content: {
            LibraryPane(bridge: bridge)
        } detail: {
            VStack(spacing: 0) {
                DetailPane(bridge: bridge)
                Spacer()
                PlayerBar(bridge: bridge)
            }
        }
    }
}
#endif
