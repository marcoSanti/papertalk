// The macOS app's entry point: the main window, its menu commands, and the app accent colour.

#if os(macOS)
import SwiftUI

extension Color {
    /// Papertalk's orange, the tint of every window.
    static let appAccent = Color(red: 0xD0/255, green: 0x70/255, blue: 0x40/255)
}

/// One window over one `AppStore`, created in the saved interface language.
@main
struct PapertalkApp: App {
    @StateObject private var store = AppStore.launch()
    /// Hands files opened from Finder (`.papertalk`, PDFs) to the store.
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color.appAccent)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { appDelegate.onOpen = { store.openFiles($0) } }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates…")) { store.requestUpdateCheck(.stable) }
                    .disabled(store.isCheckingForUpdates)
                Button(L("Check for Dev Builds…")) { store.requestUpdateCheck(.dev) }
                    .disabled(store.isCheckingForUpdates)
            }
            CommandGroup(after: .appSettings) {
                Button(L("Settings…")) { store.settingsPage = .general; store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button(L("Clear All Data…")) { store.settingsPage = .clear; store.showSettings = true }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Import PDF…")) { store.beginImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Button(L("Import Paper…")) { PaperPanels.importPapers(into: store) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
#endif
