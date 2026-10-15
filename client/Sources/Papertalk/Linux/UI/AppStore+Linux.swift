#if os(Linux)
import Foundation

extension AppStore {
    /// Open the paper's PDF in the desktop's own viewer (macOS shows it in an
    /// in-app window instead).
    func openPDF(_ id: String) {
        Task {
            if let url = await url(for: K.pdf(id)) { NSWorkspace.shared.open(url) }
        }
    }
}
#endif
