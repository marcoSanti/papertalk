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
                Button("Setup Wizard…") { store.showOnboarding = true }
                Divider()
                Button("Server Settings…") { store.settingsSheet = .connection }
                Button("LLM Settings…") { store.settingsSheet = .llm }
                Divider()
                Button("Clear All Data…") { store.settingsSheet = .clear }
            }
            CommandGroup(replacing: .newItem) { }
        }
    }
}