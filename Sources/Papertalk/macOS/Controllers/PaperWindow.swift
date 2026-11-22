// A paper's own window: every detail and action, so the inspector can stay short.

#if os(macOS)
import AppKit
import SwiftUI

/// A paper's details and actions in a window of its own (`DetailView`'s wide, three-column
/// layout). One window per paper; opening it again brings it forward. It closes itself when the
/// paper is deleted.
@MainActor
final class PaperWindow: NSObject, NSWindowDelegate, PerPaperWindow {
    static let open = WindowRegistry<PaperWindow>()

    private let paperId: String
    private(set) var window: NSWindow!
    /// The library window it was opened from: confirmations and the Edit sheet appear there.
    private weak var mainWindow: NSWindow?

    /// Open the paper's window, or bring it forward.
    static func present(paperId: String, store: AppStore) {
        open.present(paperId, make: { PaperWindow(paperId: paperId, mainWindow: NSApp.keyWindow) },
                     content: { NSHostingView(rootView: PaperWindowContent(paperId: paperId).environmentObject(store)) })
    }

    /// Bring the library window forward when this paper's window asked for a dialog that's shown there.
    static func raiseMainWindow(paperId: String) {
        guard let w = open[paperId], w.window.isKeyWindow else { return }
        w.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private init(paperId: String, mainWindow: NSWindow?) {
        self.paperId = paperId
        self.mainWindow = mainWindow
        super.init()
        window = HostedWindow.make(width: 1120, height: 700, minSize: NSSize(width: 900, height: 520), delegate: self)
    }

    /// Forget the window, so the paper's next open makes a new one.
    func windowWillClose(_ notification: Notification) {
        Self.open[paperId] = nil
    }
}

#endif
