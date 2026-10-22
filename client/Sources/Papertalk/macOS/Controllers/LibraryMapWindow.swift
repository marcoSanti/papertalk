// The library map's own window on macOS.

#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// A library's map of paper connections in a window of its own, one per library: opening it
/// again brings it forward, rebuilt. It also rebuilds when any mind map is saved.
@MainActor
final class LibraryMapWindow: NSObject, NSWindowDelegate {
    private static var windows: [String: LibraryMapWindow] = [:]

    private let libraryId: String
    private let window: NSWindow
    private let store: AppStore
    private var watching: AnyCancellable?

    /// Open (or bring forward) the library's map.
    static func open(libraryId: String, store: AppStore) {
        let w = windows[libraryId] ?? LibraryMapWindow(libraryId: libraryId, store: store)
        if windows[libraryId] == nil {
            windows[libraryId] = w
            w.window.center()
        }
        Task { await w.reload(forward: true) }
    }

    private init(libraryId: String, store: AppStore) {
        self.libraryId = libraryId
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false   // we own it
        window.minSize = NSSize(width: 760, height: 480)
        window.delegate = self
        watching = store.$mindMapRevision.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in await self?.reload(forward: false) } }
    }

    /// Rebuild the map from the saved mind maps; close if the library is gone.
    private func reload(forward: Bool) async {
        guard let library = store.libraries.first(where: { $0.id == libraryId }) else {
            window.close()
            return
        }
        let map = await store.libraryMap(libraryId)
        window.title = LibraryMapPresentation.title(library.name)
        let view = LibraryMapView(map: map) { [store] id in MindMapWindow.open(paperId: id, store: store) }
        // Swapping the root view keeps its state, so papers the user dragged stay put.
        if let host = window.contentView as? NSHostingView<LibraryMapView> {
            host.rootView = view
        } else {
            window.contentView = NSHostingView(rootView: view)
        }
        if forward { window.makeKeyAndOrderFront(nil) }
    }

    /// Forget the window, so the library's next open makes a new one.
    func windowWillClose(_ notification: Notification) {
        Self.windows[libraryId] = nil
    }
}
#endif
