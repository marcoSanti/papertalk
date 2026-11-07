// A paper's Ask window on macOS: a chat with the LLM about the paper.

#if os(macOS)
import AppKit
import SwiftUI

/// A paper's Ask chat in a window of its own. One window per paper; opening it again brings it
/// forward. The chat lives in the store, so closing the window keeps it for the next open. It
/// closes itself when the paper is deleted.
@MainActor
final class PaperChatWindow: NSObject, NSWindowDelegate {
    private static var open: [String: PaperChatWindow] = [:]

    private let paperId: String
    private let window: NSWindow

    /// Open the paper's Ask window, or bring it forward.
    static func present(paperId: String, store: AppStore) {
        if let existing = open[paperId] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let w = PaperChatWindow(paperId: paperId)
        open[paperId] = w
        w.window.contentView = NSHostingView(rootView: PaperChatView(paperId: paperId).environmentObject(store))
        w.window.center()
        w.window.makeKeyAndOrderFront(nil)
    }

    /// Close the paper's Ask window, if it's open.
    static func close(paperId: String) { open[paperId]?.window.close() }

    /// Set the window's title (follows the paper's title).
    static func setTitle(_ title: String, paperId: String) { open[paperId]?.window.title = title }

    private init(paperId: String) {
        self.paperId = paperId
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PaperChat.windowWidth, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false   // we own it
        window.minSize = NSSize(width: 800, height: 420)   // the chat (440) beside the narrowest paper pane
        window.delegate = self
    }

    /// Forget the window, so the paper's next open makes a new one.
    func windowWillClose(_ notification: Notification) {
        Self.open[paperId] = nil
    }
}
#endif
