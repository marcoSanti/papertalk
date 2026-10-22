// Wording and small rules for the main window: its confirmation dialogs, the sort menu,
// the resizable details panel, and picking a PDF out of a drop.

import Foundation

/// Wording for the main window's confirmation dialogs.
struct ConfirmationText: Equatable {
    /// The question, naming the paper.
    let title: String
    /// The destructive button.
    let confirmLabel: String
    /// What will happen, under the title.
    let message: String
    /// The button that keeps everything as it is.
    var cancelLabel = L("Cancel")
    /// A third choice, besides confirming and cancelling.
    var secondaryLabel: String?

    /// The wording for a confirmation the store is waiting on.
    init(_ pending: AppStore.PendingConfirmation) {
        switch pending {
        case .delete(let p):
            title = L("Delete “{0}”?", p.displayTitle)
            confirmLabel = L("Delete paper")
            message = (p.isActive ? L("Its conversion is stopped first.") + " " : "")
                + L("The PDF, transcript and generated audio are removed from the library. This can’t be undone.")
        case .rerun(let p):
            title = L("Rerun “{0}”?", p.displayTitle)
            confirmLabel = L("Rerun episode")
            message = L("The current script and audio are replaced with a newly written episode.")
        case .deleteAudio(let p):
            title = L("Delete the audio of “{0}”?", p.displayTitle)
            confirmLabel = L("Delete audio")
            message = Self.keptAfterAudio
        case .finishedListening(let p):
            title = L("You finished “{0}”", p.displayTitle)
            confirmLabel = L("Delete audio")
            message = L("Delete its audio to free up space?") + " " + Self.keptAfterAudio
            cancelLabel = L("Keep audio")
            secondaryLabel = L("Keep, and don’t ask again")
        case .redrawAllMindMaps(let count):
            title = L("Redraw all mind maps?")
            confirmLabel = L("Redraw mind maps")
            message = L("{0} get a new mind map from their PDF, one after another, with one LLM request each. Changes you made to the current maps are lost.",
                        LibraryPresentation.paperCount(count))
        }
    }

    private static var keptAfterAudio: String {
        L("The script and PDF stay. You can still play the episode with live voices, or voice it again with Regenerate audio.")
    }

    /// Title and message together, for alerts that only show a title (Linux).
    var combined: String { "\(title)\n\(message)" }

    /// The "already in your library" question during an import.
    static func duplicate(of existing: Paper) -> ConfirmationText {
        ConfirmationText(title: L("Already in library"), confirmLabel: L("Import anyway"),
                         message: L("“{0}” already exists with the same title or DOI. Import it anyway?", existing.displayTitle))
    }

    private init(title: String, confirmLabel: String, message: String) {
        self.title = title; self.confirmLabel = confirmLabel; self.message = message
    }
}

extension SortOption {
    /// The sort menu's entry.
    var label: String {
        switch self {
        case .newest: return L("Newest first")
        case .oldest: return L("Oldest first")
        case .title: return L("Title")
        case .recent: return L("Recently converted")
        }
    }
}

/// The resizable details panel on the right of the main window.
enum InspectorLayout {
    /// How narrow and wide the panel may be dragged.
    static let widthRange = 300.0...520.0
    /// Its width until the user drags it.
    static let defaultWidth = 340.0

    /// Width while dragging the divider: dragging left widens the panel.
    static func width(startingAt start: Double, dragged dx: Double) -> Double {
        min(widthRange.upperBound, max(widthRange.lowerBound, start - dx))
    }
}

/// Picking the file out of a drag-and-drop onto the library or import sheet.
enum ImportPresentation {
    /// The first `.pdf` among dropped files; others are ignored.
    static func firstPDF(in urls: [URL]) -> URL? {
        urls.first { $0.pathExtension.lowercased() == "pdf" }
    }
}
