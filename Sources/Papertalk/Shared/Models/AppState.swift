// The values the app's state is made of: what the library shows and how, a question waiting
// for the user, the suggestions being imported and the voice sample being played.

import Foundation

/// What the library shows: every paper, favourites, the Authors screen, one tag, one author,
/// one library, or the slide decks (kept apart: no other view shows them).
enum ViewMode { case all, fav, authors, tag, author, library, slides, suggested }

/// What the sidebar can point the library at.
enum SidebarItem: Hashable {
    case all, favorites, authors, slides, suggested, tag(String), library(String)
}

/// The library's sort orders (wording in `SortOption.label`).
enum SortOption: String, CaseIterable, Identifiable {
    case newest, oldest, title = "Title", recent = "Recently converted"
    var id: String { rawValue }
}

/// Covers in a grid, or rows in a list.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid = "Grid", list = "List"
    var id: String { rawValue }
}

/// A destructive action waiting for the user's yes (see `ConfirmationText` for the wording).
enum PendingConfirmation: Identifiable {
    case delete(Paper), rerun(Paper), deleteAudio(Paper)
    /// An episode was listened to the end: keep its audio or free the space?
    case finishedListening(Paper)
    /// Redraw the mind maps of this many papers (`mindMapsToRedraw`), replacing them.
    case redrawAllMindMaps(Int)
    /// Delete a library; its papers stay, in no library.
    case deleteLibrary(Library)
    var id: String {
        switch self {
        case .delete(let p): return "delete-\(p.id)"
        case .rerun(let p): return "rerun-\(p.id)"
        case .deleteAudio(let p): return "deleteAudio-\(p.id)"
        case .finishedListening(let p): return "finished-\(p.id)"
        case .redrawAllMindMaps: return "redrawAllMindMaps"
        case .deleteLibrary(let library): return "deleteLibrary-\(library.id)"
        }
    }
}

/// The chosen suggestions being imported, one at a time, and where the current one is.
struct PaperFetch: Equatable {
    /// What happens to the current paper now.
    enum Step: Equatable {
        /// Downloading its free PDF.
        case downloading
        /// Waiting for the user to download its PDF in the browser.
        case waiting
        /// A PDF arrived (its file name) and is being imported.
        case importing(String)
    }
    var current: Suggestion
    /// The ones after it.
    var queue: [Suggestion]
    var step: Step
    /// How many were chosen, and the position of `current` (from 1).
    var total: Int
    var position: Int
    /// The library each chosen suggestion is filed in, by suggestion id; missing: no library.
    var libraries: [String: String] = [:]
}

/// Voice-sample preview, independent of the episode being listened to.
enum PreviewPhase: Equatable {
    case generating(String)          // synthesizing the sample for this voice
    case playing(String)
    case failed(String, String)      // voice, message
    var voice: String {
        switch self { case .generating(let v), .playing(let v), .failed(let v, _): return v }
    }
}

/// What a system notification is about: ready, failed (with why), a question waiting (with the
/// question), or new suggested papers (with how many).
enum NotificationEvent {
    case ready, failed(String), needsInput(String), suggestions(String)
}

/// The pace voices speak at.
enum SpeakingPace {
    /// Slightly under 1: Kokoro reads clearer a little slower.
    static let defaultSpeed = 0.95
    /// What the pace slider allows.
    static let range = 0.5...2.0
}
