// A paper's own window: every detail and action, so the inspector can stay short.

#if os(macOS)
import AppKit
import SwiftUI

/// A paper's details and actions in a window of its own (`DetailView`'s wide, three-column
/// layout). One window per paper; opening it again brings it forward. It closes itself when the
/// paper is deleted.
@MainActor
final class PaperWindow: NSObject, NSWindowDelegate {
    private static var open: [String: PaperWindow] = [:]

    private let paperId: String
    private let window: NSWindow
    /// The library window it was opened from: confirmations and the Edit sheet appear there.
    private weak var mainWindow: NSWindow?

    /// Open the paper's window, or bring it forward.
    static func present(paperId: String, store: AppStore) {
        if let existing = open[paperId] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let w = PaperWindow(paperId: paperId, mainWindow: NSApp.keyWindow)
        open[paperId] = w
        w.window.contentView = NSHostingView(rootView: PaperWindowContent(paperId: paperId).environmentObject(store))
        w.window.center()
        w.window.makeKeyAndOrderFront(nil)
    }

    /// Close the paper's window, if it's open.
    static func close(paperId: String) { open[paperId]?.window.close() }

    /// Set the window's title (the paper's title, which can be edited in the window).
    static func setTitle(_ title: String, paperId: String) { open[paperId]?.window.title = title }

    /// Bring the library window forward when this paper's window asked for a dialog that's shown there.
    static func raiseMainWindow(paperId: String) {
        guard let w = open[paperId], w.window.isKeyWindow else { return }
        w.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private init(paperId: String, mainWindow: NSWindow?) {
        self.paperId = paperId
        self.mainWindow = mainWindow
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false   // we own it
        window.minSize = NSSize(width: 900, height: 520)
        window.delegate = self
    }

    /// Forget the window, so the paper's next open makes a new one.
    func windowWillClose(_ notification: Notification) {
        Self.open[paperId] = nil
    }
}

/// The window's content: the live paper from the store, with every card.
private struct PaperWindowContent: View {
    @EnvironmentObject private var store: AppStore
    let paperId: String

    var body: some View {
        Group {
            if let paper = store.papers[paperId] {
                DetailView(paper: paper, onEdit: { store.editingPaper = paper }, inWindow: true)
                    .onAppear { PaperWindow.setTitle(paper.displayTitle, paperId: paperId) }
                    .onChange(of: paper.displayTitle) { _, title in PaperWindow.setTitle(title, paperId: paperId) }
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .tint(Color.appAccent)
        .onChange(of: store.papers[paperId] == nil) { _, gone in
            if gone { PaperWindow.close(paperId: paperId) }
        }
        // Confirmations and the Edit sheet are presented by the library window.
        .onChange(of: store.pendingConfirmation != nil || store.editingPaper != nil) { _, shown in
            if shown { PaperWindow.raiseMainWindow(paperId: paperId) }
        }
    }
}
#endif
