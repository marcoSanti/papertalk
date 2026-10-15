import SpikeCore
import Foundation
import SwiftCrossUI

/// SwiftCrossUI has its own ObservableObject (didChange-based), so it can't watch
/// an OpenCombine store directly. This forwards every store change to it.
@MainActor
final class StoreBridge: SwiftCrossUI.ObservableObject {
    let store: Store
    @SwiftCrossUI.Published var revision = 0

    init(_ store: Store) {
        self.store = store
        store.onChange { [weak self] in self?.revision += 1 }
        Demo.run(store)
    }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Store, T>) -> Binding<T> {
        Binding(get: { self.store[keyPath: keyPath] }, set: { self.store[keyPath: keyPath] = $0 })
    }
}

/// SPIKE_DEMO=1: drive the store on a timer, so headless screenshots show
/// whether store changes reach the GTK views.
@MainActor
enum Demo {
    static func run(_ store: Store) {
        guard ProcessInfo.processInfo.environment["SPIKE_DEMO"] == "1" else { return }
        if let path = ProcessInfo.processInfo.environment["SPIKE_COVER"],
           let png = FileManager.default.contents(atPath: path) {
            store.papers[0].cover = png
        }
        let steps: [(Double, @MainActor () -> Void)] = [
            (3, { store.selectedId = "1" }),
            (6, { store.search = "deep" }),
            (9, { store.selectedId = "2"; store.requestDelete() }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { step() } }
        }
    }
}
