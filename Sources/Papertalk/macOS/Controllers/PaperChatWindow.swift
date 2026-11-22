// A paper's Ask window on macOS: a chat with the LLM about the paper.

#if os(macOS)
import AppKit
import SwiftUI

/// A paper's Ask chat in a window of its own. One window per paper; opening it again brings it
/// forward. The chat lives in the store, so closing the window keeps it for the next open. It
/// closes itself when the paper is deleted.
@MainActor
final class PaperChatWindow: NSObject, NSWindowDelegate, PerPaperWindow {
    static let open = WindowRegistry<PaperChatWindow>()

    private let paperId: String
    private(set) var window: NSWindow!

    /// Open the paper's Ask window, or bring it forward.
    static func present(paperId: String, store: AppStore) {
        open.present(paperId, make: { PaperChatWindow(paperId: paperId) },
                     content: { NSHostingView(rootView: PaperChatView(paperId: paperId).environmentObject(store)) })
    }

    private init(paperId: String) {
        self.paperId = paperId
        super.init()
        window = HostedWindow.make(width: PaperChat.windowWidth, height: 760,
                                   minSize: NSSize(width: 800, height: 420),   // the chat (440) beside the narrowest paper pane
                                   delegate: self)
    }

    /// Forget the window, so the paper's next open makes a new one.
    func windowWillClose(_ notification: Notification) {
        Self.open[paperId] = nil
    }
}
#endif
