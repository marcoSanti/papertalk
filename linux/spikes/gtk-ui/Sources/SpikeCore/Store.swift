import Foundation
import OpenCombine

public struct Paper: Identifiable, Equatable {
    public let id: String
    public var title: String
    public var cover: Data?
    public init(id: String, title: String, cover: Data?) { self.id = id; self.title = title; self.cover = cover }
}

/// Shaped like AppStore: a main-actor ObservableObject with @Published state.
@MainActor
public final class Store: ObservableObject {
    @Published public var papers: [Paper]
    @Published public var selectedId: String?
    @Published public var search = ""
    @Published public var pendingDelete: Paper?
    @Published public var showImport = false
    @Published public private(set) var log: [String] = []
    private var bag: Set<AnyCancellable> = []

    public init(papers: [Paper]) { self.papers = papers }

    public var filtered: [Paper] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? papers : papers.filter { $0.title.lowercased().contains(q) }
    }

    public func requestDelete() { pendingDelete = papers.first { $0.id == selectedId } }
    public func confirmDelete() {
        guard let p = pendingDelete else { return }
        papers.removeAll { $0.id == p.id }
        selectedId = nil
        pendingDelete = nil
        log.append("deleted \(p.title)")
    }
    public func importFile(_ url: URL) {
        papers.append(Paper(id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent, cover: nil))
        showImport = false
        log.append("imported \(url.lastPathComponent)")
    }

    /// The one hook a UI toolkit needs: called after any published change.
    /// Keeps OpenCombine out of the UI layer.
    public func onChange(_ action: @escaping @MainActor () -> Void) {
        objectWillChange
            .sink { _ in DispatchQueue.main.async { MainActor.assumeIsolated { action() } } }
            .store(in: &bag)
    }
}
