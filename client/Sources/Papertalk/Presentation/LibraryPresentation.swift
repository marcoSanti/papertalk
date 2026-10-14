import Foundation

/// What the sidebar can point the library at.
enum SidebarItem: Hashable {
    case all, favorites, authors, tag(String)
}

/// Library wording and keyboard navigation. Pure functions: the library and
/// sidebar views only lay out what these return.
enum LibraryPresentation {
    static func title(view: AppStore.ViewMode, tag: String?, author: String?) -> String {
        switch view {
        case .all: return "All Papers"
        case .fav: return "Favorites"
        case .authors: return "Authors"
        case .tag: return tag.map { "#\($0)" } ?? "Tag"
        case .author: return author ?? "Author"
        }
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        n == 1 ? "1 \(singular)" : "\(n) \(plural)"
    }
    static func paperCount(_ n: Int) -> String { count(n, "paper", "papers") }
    static func authorCount(_ n: Int) -> String { count(n, "author", "authors") }

    /// A count shown beside a section title, hidden when there's nothing.
    static func badge(_ n: Int) -> String? { n > 0 ? "\(n)" : nil }

    /// Authors screen subtitle (empty while there are no authors).
    static func authorsSubtitle(_ n: Int) -> String { n > 0 ? authorCount(n) : "" }

    /// The sidebar footer: where the library lives.
    static func storageLocation(isStandalone: Bool) -> (icon: String, title: String) {
        isStandalone ? ("desktopcomputer", "On this Mac") : ("server.rack", "Library server")
    }

    /// The status filter capsules above the library. `value` is the store's
    /// `statusFilter` value ("running" also matches queued papers).
    struct StatusFilter: Identifiable, Equatable {
        let value: String, title: String, icon: String
        var id: String { value }
    }
    static let statusFilters: [StatusFilter] = [
        .init(value: "all", title: "All", icon: "square.stack"),
        .init(value: "running", title: "Converting", icon: "hourglass"),
        .init(value: "done", title: "Ready", icon: "waveform"),
        .init(value: "error", title: "Failed", icon: "exclamationmark.triangle"),
    ]

    /// What the library shows when no paper matches.
    enum EmptyState: Equatable {
        case emptyLibrary
        case noSearchResults(String)
        case filteredOut
    }
    static func emptyState(libraryIsEmpty: Bool, search: String) -> EmptyState {
        if libraryIsEmpty { return .emptyLibrary }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return .noSearchResults(search) }
        return .filteredOut
    }

    // MARK: grid keyboard navigation

    /// Grid geometry, shared with `LibraryView`'s adaptive `GridItem` so the
    /// keyboard's idea of a row matches what's on screen.
    enum Grid {
        static let minTile = 150.0, maxTile = 210.0, spacing = 22.0, sidePadding = 22.0
    }

    /// Columns the adaptive grid fits into `width`.
    static func gridColumns(width: Double) -> Int {
        max(1, Int((width - 2 * Grid.sidePadding + Grid.spacing) / (Grid.minTile + Grid.spacing)))
    }

    enum Move { case left, right, up, down }

    /// Index to select after an arrow key: left/right step one paper, up/down a
    /// whole row, clamped to the list. With nothing selected, the first paper.
    static func nextIndex(from current: Int?, move: Move, columns: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let step: Int
        switch move {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(1, columns)
        case .down: step = max(1, columns)
        }
        guard let current else { return 0 }
        return min(count - 1, max(0, current + step))
    }
}
