// The library's wording and navigation: sidebar rows and titles, counts, status filters,
// empty states, and how arrow keys move through the cover grid.

import Foundation

/// Library wording and keyboard navigation. Pure functions: the library and
/// sidebar views only lay out what these return.
enum LibraryPresentation {
    /// The heading above the library for the current scope.
    static func title(view: ViewMode, tag: String?, author: String?, library: String? = nil) -> String {
        switch view {
        case .all: return sidebarTitle(.all)
        case .fav: return sidebarTitle(.favorites)
        case .authors: return sidebarTitle(.authors)
        case .tag: return tag.map { "#\($0)" } ?? L("Tag")
        case .author: return author ?? L("Author")
        case .library: return library ?? L("Library")
        case .slides: return sidebarTitle(.slides)
        case .suggested: return sidebarTitle(.suggested)
        }
    }

    /// A sidebar row's name (tags without the "#" the library title adds).
    static func sidebarTitle(_ item: SidebarItem, libraries: [Library] = []) -> String {
        switch item {
        case .all: return L("All Papers")
        case .favorites: return L("Favorites")
        case .authors: return L("Authors")
        case .tag(let tag): return tag
        case .library(let id): return libraries.first { $0.id == id }?.name ?? L("Library")
        case .slides: return L("Slides")
        case .suggested: return SuggestionsPresentation.windowTitle
        }
    }

    /// The chain beside a library whose mind maps connect to other libraries; nil otherwise.
    static func crossLinkMark(_ library: Library) -> (icon: String, help: String)? {
        library.connectsAcross ? ("link", L("Mind maps connect to other libraries")) : nil
    }

    /// When something wasn't saved, because saving over what couldn't be read would lose it.
    static var unreadable: String {
        L("The library couldn't be read. Check the storage server or library folder, then try again.")
    }

    /// `one` for 1, else `other` with {0} replaced by the count ("{0} papers").
    static func count(_ n: Int, _ one: String, _ other: String) -> String {
        n == 1 ? one : other.replacingOccurrences(of: "{0}", with: "\(n)")
    }
    /// "1 paper" / "3 papers".
    static func paperCount(_ n: Int) -> String { count(n, L("1 paper"), L("{0} papers")) }

    /// The library header's count: decks in Slides, papers everywhere else.
    static func itemCount(_ n: Int, slides: Bool) -> String {
        slides ? count(n, L("1 deck"), L("{0} decks")) : paperCount(n)
    }
    /// "1 author" / "3 authors".
    static func authorCount(_ n: Int) -> String { count(n, L("1 author"), L("{0} authors")) }

    /// A count shown beside a section title, hidden when there's nothing.
    static func badge(_ n: Int) -> String? { n > 0 ? "\(n)" : nil }

    /// Authors screen subtitle (empty while there are no authors).
    static func authorsSubtitle(_ n: Int) -> String { n > 0 ? authorCount(n) : "" }

    /// The sidebar footer: where the library lives.
    static func storageLocation(isStandalone: Bool) -> (icon: String, title: String) {
        isStandalone ? ("desktopcomputer", Device.on) : ("server.rack", L("Library server"))
    }

    /// The status filter capsules above the library. `value` is the store's
    /// `statusFilter` value ("running" also matches queued papers).
    struct StatusFilter: Identifiable, Equatable {
        let value: String, title: String, icon: String
        var id: String { value }
    }
    /// The capsules, left to right.
    static var statusFilters: [StatusFilter] { [
        .init(value: "all", title: L("All"), icon: "square.stack"),
        .init(value: "running", title: L("Converting"), icon: "hourglass"),
        .init(value: "done", title: L("Ready"), icon: "waveform"),
        .init(value: "error", title: L("Failed"), icon: "exclamationmark.triangle"),
    ] }

    /// What the library shows when no paper matches.
    enum EmptyState: Equatable {
        case emptyLibrary
        /// The Slides library has no decks yet.
        case noSlides
        case noSearchResults(String)
        case filteredOut
    }
    /// Heading and explanation for an empty library view.
    static func emptyStateText(_ state: EmptyState) -> (title: String, message: String) {
        switch state {
        case .emptyLibrary:
            return (L("Your library is empty"),
                    L("Import a PDF and Papertalk will turn it into a podcast episode, right on {0}.", Device.this))
        case .noSlides:
            return (L("No slide decks yet"),
                    L("Import a presentation as a PDF: Papertalk reads each slide, describes the pictures, and turns it into an episode."))
        case .noSearchResults(let text):
            return (L("No results for “{0}”", text.trimmingCharacters(in: .whitespaces)), L("Check the spelling or try a new search."))
        case .filteredOut:
            return (L("Nothing here"), L("No papers match the current filters."))
        }
    }

    /// The empty Slides library's import button.
    static var importSlides: String { L("Import slides…") }

    /// The details pane with nothing selected.
    static var noSelection: (title: String, message: String) {
        (L("No paper selected"), L("Select a paper to see its details and episode."))
    }

    /// The macOS details pane with nothing selected, worded for decks in Slides.
    static func detailPlaceholder(slides: Bool) -> (title: String, message: String) {
        slides ? (L("No deck selected"), L("Pick a deck to see its details, tags and episode."))
            : (L("No paper selected"), L("Pick a paper from the library to see its details, tags and episode."))
    }

    /// Which empty state applies: an empty library, a search with no hits, or filters that hide everything.
    static func emptyState(libraryIsEmpty: Bool, search: String, noSlides: Bool = false) -> EmptyState {
        if noSlides { return .noSlides }
        if libraryIsEmpty { return .emptyLibrary }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return .noSearchResults(search) }
        return .filteredOut
    }

    // MARK: grid keyboard navigation

    /// Grid geometry, shared with `LibraryView`'s adaptive `GridItem` so the
    /// keyboard's idea of a row matches what's on screen.
    enum Grid {
        static let minTile = 150.0, maxTile = 210.0, spacing = 22.0, sidePadding = 22.0
        /// Slide tiles are wider: a 16:9 cover at paper width is too small to read.
        static let minSlideTile = 260.0, maxSlideTile = 360.0

        /// A tile's width bounds, for the papers or the Slides library.
        static func tile(slides: Bool) -> (min: Double, max: Double) {
            slides ? (minSlideTile, maxSlideTile) : (minTile, maxTile)
        }
    }

    /// Columns the adaptive grid fits into `width` (wider tiles in Slides).
    static func gridColumns(width: Double, slides: Bool = false) -> Int {
        max(1, Int((width - 2 * Grid.sidePadding + Grid.spacing) / (Grid.tile(slides: slides).min + Grid.spacing)))
    }

    /// An arrow key.
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
