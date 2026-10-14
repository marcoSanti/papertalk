import SwiftUI

extension Color {
    static let appAccent = Color(red: 0xD0/255, green: 0x70/255, blue: 0x40/255)
}

@main
struct PapertalkApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color.appAccent)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Settings…") { store.settingsPage = .llm; store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Clear All Data…") { store.settingsPage = .clear; store.showSettings = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Import PDF…") { store.beginImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}