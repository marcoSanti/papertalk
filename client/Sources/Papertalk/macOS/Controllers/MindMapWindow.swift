#if os(macOS)
import AppKit
import SwiftUI

/// A paper's mind map in a window of its own: it can be resized, maximised
/// (the green button fills the screen) and closed, but not minimised. One
/// window per paper; opening it again brings it forward with the latest map.
@MainActor
final class MindMapWindow: NSObject, NSWindowDelegate {
    private static var open: [String: MindMapWindow] = [:]

    private let paperId: String
    private let window: NSWindow

    static func present(map: MindMap, title: String, paperId: String) {
        if let existing = open[paperId] {
            existing.show(map: map, title: title)
            return
        }
        let w = MindMapWindow(paperId: paperId)
        open[paperId] = w
        w.show(map: map, title: title)
        w.window.center()
    }

    private init(paperId: String) {
        self.paperId = paperId
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                          styleMask: [.titled, .closable, .resizable],   // no .miniaturizable
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false   // we own it
        window.minSize = NSSize(width: 760, height: 480)
        // The green button maximises in place instead of opening a full-screen space.
        window.collectionBehavior = [.fullScreenNone]
        window.delegate = self
    }

    private func show(map: MindMap, title: String) {
        window.title = "\(MindMapPresentation.heading) — \(title)"
        window.contentView = NSHostingView(rootView: MindMapView(map: map, title: title) { [weak self] in
            self?.window.performClose(nil)
        })
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[paperId] = nil
    }
}
#endif
