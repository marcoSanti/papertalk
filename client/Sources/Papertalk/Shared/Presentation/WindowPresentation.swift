import Foundation

/// Wording for the main window's confirmation dialogs.
struct ConfirmationText: Equatable {
    let title: String
    let confirmLabel: String
    let message: String

    init(_ pending: AppStore.PendingConfirmation) {
        switch pending {
        case .delete(let p):
            title = "Delete “\(p.displayTitle)”?"
            confirmLabel = "Delete paper"
            message = "The PDF, transcript and generated audio are removed from the library. This can’t be undone."
        case .rerun(let p):
            title = "Rerun “\(p.displayTitle)”?"
            confirmLabel = "Rerun episode"
            message = "The current script and audio are replaced with a newly written episode."
        }
    }

    /// Title and message together, for alerts that only show a title (Linux).
    var combined: String { "\(title)\n\(message)" }

    /// The "already in your library" question during an import.
    static func duplicate(of existing: Paper) -> ConfirmationText {
        ConfirmationText(title: "Already in library", confirmLabel: "Import anyway",
                         message: "“\(existing.displayTitle)” already exists with the same title or DOI. Import it anyway?")
    }

    private init(title: String, confirmLabel: String, message: String) {
        self.title = title; self.confirmLabel = confirmLabel; self.message = message
    }
}

extension SortOption {
    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .title: return "Title"
        case .recent: return "Recently converted"
        }
    }
}

/// The resizable details panel on the right of the main window.
enum InspectorLayout {
    static let widthRange = 300.0...520.0
    static let defaultWidth = 340.0

    /// Width while dragging the divider: dragging left widens the panel.
    static func width(startingAt start: Double, dragged dx: Double) -> Double {
        min(widthRange.upperBound, max(widthRange.lowerBound, start - dx))
    }
}

/// Picking the file out of a drag-and-drop onto the library or import sheet.
enum ImportPresentation {
    static func firstPDF(in urls: [URL]) -> URL? {
        urls.first { $0.pathExtension.lowercased() == "pdf" }
    }
}
