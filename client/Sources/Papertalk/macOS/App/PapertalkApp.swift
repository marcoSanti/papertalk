#if os(macOS)
import SwiftUI

extension Color {
    static let appAccent = Color(red: 0xD0/255, green: 0x70/255, blue: 0x40/255)
}

@main
struct PapertalkApp: App {
    @StateObject private var store = AppStore.launch()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color.appAccent)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates…")) { store.requestUpdateCheck(.stable) }
                    .disabled(store.isCheckingForUpdates)
                Button(L("Check for Dev Builds…")) { store.requestUpdateCheck(.dev) }
                    .disabled(store.isCheckingForUpdates)
            }
            CommandGroup(after: .appSettings) {
                Button(L("Settings…")) { store.settingsPage = .llm; store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button(L("Clear All Data…")) { store.settingsPage = .clear; store.showSettings = true }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Import PDF…")) { store.beginImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
#endif
