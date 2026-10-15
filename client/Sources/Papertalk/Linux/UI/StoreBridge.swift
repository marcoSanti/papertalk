#if os(Linux)
import Foundation
import ImageFormats
import OpenCombine
import SwiftCrossUI

/// Lets SwiftCrossUI views follow the shared AppStore. SwiftCrossUI has its own
/// ObservableObject (`didChange`), so this forwards every change of the store
/// and of its player (a separate ObservableObject) as one `revision` bump. It's
/// the only UI file that sees OpenCombine; views read `bridge.store` directly.
@MainActor
final class StoreBridge: SwiftCrossUI.ObservableObject {
    let store: AppStore
    @SwiftCrossUI.Published private(set) var revision = 0
    /// True shortly after the window first appears. Sheets wanted at launch
    /// (first-run setup, a PDF from the command line) wait for it: SwiftCrossUI
    /// drops presentations asked for before then or during the first layout.
    @SwiftCrossUI.Published private(set) var windowReady = false
    private var subscriptions: Set<OpenCombine.AnyCancellable> = []

    /// Decoded covers by paper id, kept per artwork revision.
    private var covers: [String: (revision: Int, image: ImageFormats.Image<RGBA>?)] = [:]
    private var loadingCovers: Set<String> = []

    init(_ store: AppStore) {
        self.store = store
        // objectWillChange fires before the change lands: re-render on the next turn.
        let bump: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.revision += 1 } }
        }
        store.objectWillChange.sink { _ in bump() }.store(in: &subscriptions)
        store.player.objectWillChange.sink { _ in bump() }.store(in: &subscriptions)
        store.trackPlayback()
    }

    /// Called when the window appears: marks it ready (on the next turn, after
    /// the first layout), then `Papertalk paper.pdf` (and "Open with" from a
    /// file manager) opens the import sheet with that PDF.
    func windowAppeared() {
        guard !windowReady else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                self.windowReady = true
                let arguments = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
                if let pdf = ImportPresentation.firstPDF(in: arguments) { self.store.beginImport(pdf) }
            }
        }
    }

    /// Two-way binding to a store property.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<AppStore, T>) -> Binding<T> {
        Binding(get: { self.store[keyPath: keyPath] }, set: { self.store[keyPath: keyPath] = $0 })
    }

    /// The paper's cover if it's decoded; otherwise starts loading it and
    /// returns nil (the view re-renders when it arrives).
    func cover(_ id: String) -> ImageFormats.Image<RGBA>? {
        let artwork = store.artworkRevision[id] ?? 0
        if let cached = covers[id], cached.revision == artwork { return cached.image }
        guard !loadingCovers.contains(id) else { return covers[id]?.image }
        loadingCovers.insert(id)
        Task {
            let png = await store.loadThumbnail(id)?.png
            let image = png.flatMap { try? ImageFormats.Image<RGBA>.load(from: Array($0), as: .png) }
            covers[id] = (artwork, image)
            loadingCovers.remove(id)
            revision += 1
        }
        return covers[id]?.image
    }
}
#endif
