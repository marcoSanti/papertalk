#if os(Linux)
import Foundation

extension AppStore {
    /// Close the settings sheet; on first launch, where it's the setup,
    /// closing skips the setup (everything can be set there later).
    func closeSettings() {
        showSettings = false
        if showOnboarding { markOnboarded() }
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
