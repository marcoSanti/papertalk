import Foundation

/// Wording for the main window's confirmation dialogs.
struct ConfirmationText: Equatable {
    let title: String
    let confirmLabel: String
    let message: String
    var cancelLabel = L("Cancel")
    /// A third choice, besides confirming and cancelling.
    var secondaryLabel: String?

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
