// The mind map's own window on macOS.

#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// A paper's mind map in a window of its own: it can be resized, maximised
/// (the green button fills the screen) and closed, but not minimised. One
/// window per paper; opening it again brings it forward with the latest map. Opened from the
/// store, it also reloads when the map changes elsewhere (a connection added from another paper),
/// and opening a connected paper's map from it swaps that map in, with a cross-fade.
@MainActor
final class MindMapWindow: NSObject, NSWindowDelegate {
    private static var windows: [String: MindMapWindow] = [:]

    /// The paper shown; changes when a connected paper's map is opened in this window.
    private var paperId: String
    private let window: NSWindow
    /// The map on screen, the window's own edits included: a saved map that differs changed elsewhere.
    private var shown: MindMap?
    /// Set for windows opened from the store: edits are saved and connected maps open here.
    private var store: AppStore?
    private var onSave: ((MindMap) -> Void)?
    private var onOpenPaper: ((String) -> Void)?
    private var watching: AnyCancellable?

    /// Open a paper's mind map window, reading the saved map now (Redraw may have replaced it):
    /// edits are saved, and other papers' concepts on it open their maps in the same window.
    static func open(paperId: String, store: AppStore) {
        Task { await load(paperId, store: store, replacing: nil) }
    }

    /// Open a connected paper's map from the window showing `current`'s, in that same window.
    static func openConnected(_ paperId: String, from current: String, store: AppStore) {
        Task { await load(paperId, store: store, replacing: windows[current]) }
    }

    /// Show `paperId`'s map: in the window already showing it, else in `current` (swapped in),
    /// else in a new window.
    private static func load(_ paperId: String, store: AppStore, replacing current: MindMapWindow?) async {
        guard let map = await store.mindMap(for: paperId), let paper = store.papers[paperId] else {
            store.show(MindMapPresentation.missingMessage)
            return
        }
        let w: MindMapWindow
        if let existing = windows[paperId] {
            w = existing
        } else if let current {
            current.attach(store)
            current.swap(to: paperId, map: map, title: paper.displayTitle)
            return
        } else {
            w = MindMapWindow(paperId: paperId)
            windows[paperId] = w
            w.window.center()
        }
        w.attach(store)
        w.show(map: map, title: paper.displayTitle)
    }

    /// Save edits and open connected maps through `store`, and reload when it saves the shown map.
    private func attach(_ store: AppStore) {
        self.store = store
        onSave = { [weak self, store] map in
            guard let self else { return }
            self.shown = map
            store.saveMindMap(self.paperId, map)
        }
        onOpenPaper = { [weak self, store] other in
            guard let self else { return }
            Self.openConnected(other, from: self.paperId, store: store)
        }
        guard watching == nil else { return }
        watching = store.$mindMapRevision.map { [weak self] revisions in self.map { revisions[$0.paperId] ?? 0 } ?? 0 }
            .removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in await self?.reload() } }
    }

    /// Show the saved map if it changed, without bringing the window forward.
    private func reload() async {
        guard let store, let map = await store.mindMap(for: paperId), map != shown,
              let paper = store.papers[paperId] else { return }
        show(map: map, title: paper.displayTitle, forward: false)
    }

    /// Open the paper's mind map window, or bring it forward showing `map`.
    /// `onSave` keeps the window's edits; without it the map is read-only.
    static func present(map: MindMap, title: String, paperId: String, onSave: ((MindMap) -> Void)? = nil,
                        onOpenPaper: ((String) -> Void)? = nil) {
        let w = windows[paperId] ?? MindMapWindow(paperId: paperId)
        if windows[paperId] == nil {
            windows[paperId] = w
            w.window.center()
        }
        w.onSave = onSave
        w.onOpenPaper = onOpenPaper
        w.show(map: map, title: title)
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

    /// Put `map` in the window and, unless reloading, bring it forward.
    private func show(map: MindMap, title: String, forward: Bool = true) {
        shown = map
        window.title = "\(MindMapPresentation.heading) — \(title)"
        window.contentView = NSHostingView(rootView: MindMapView(map: map, title: title, onSave: onSave, onOpenPaper: onOpenPaper))
        if forward { window.makeKeyAndOrderFront(nil) }
    }

    /// Show another paper's map in this window: the current map fades out, the new one fades in
    /// (at once with Reduce motion).
    private func swap(to id: String, map: MindMap, title: String) {
        Self.windows[paperId] = nil
        paperId = id
        Self.windows[id] = self
        let fade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            window.contentView?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.paperId == id else { return }   // another swap started meanwhile
                self.show(map: map, title: title)
                self.window.contentView?.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = fade
                    self.window.contentView?.animator().alphaValue = 1
                }
            }
        })
    }

    /// Forget the window, so the paper's next open makes a new one.
    func windowWillClose(_ notification: Notification) {
        Self.windows[paperId] = nil
    }
}
#endif
