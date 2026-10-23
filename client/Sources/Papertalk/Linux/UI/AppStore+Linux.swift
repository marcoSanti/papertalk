// AppStore methods only the Linux interface needs.

#if os(Linux)
import Foundation

extension AppStore {
    /// Close the settings sheet; on first launch, where it's the setup,
    /// closing skips the setup (everything can be set there later).
    func closeSettings() {
        showSettings = false
        if showOnboarding { markOnboarded() }
    }

    /// The settings sheet's Save: finish the first-run setup, or save the changes. Returns the
    /// status line to show ("Saved"), nil when the sheet closes instead.
    func saveSettingsSheet(isSetup: Bool, llm next: LLMSettings, server: ServerConfig) -> String? {
        if isSetup {
            finishSetup(server: server, llm: next, speech: speech)
            return nil
        }
        saveLLMSettings(next)
        saveServerSettings(server)
        return L("Saved")
    }

    /// Open the paper's PDF in the desktop's own viewer (macOS shows it in an
    /// in-app window instead).
    func openPDF(_ id: String) {
        Task {
            if let url = await url(for: K.pdf(id)) { NSWorkspace.shared.open(url) }
        }
    }
}
#endif
