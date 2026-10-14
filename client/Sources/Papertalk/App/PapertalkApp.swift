import SwiftUI

@main
struct PapertalkApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Settings…") { store.settingsPage = .llm; store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Clear All Data…") { store.settingsPage = .clear; store.showSettings = true }
            }
            CommandGroup(replacing: .newItem) { }
        }
    }
}