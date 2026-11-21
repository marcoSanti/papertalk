// Wording and decisions of the Suggested section: its header (the daily check's switch and
// status), each suggestion's row and details, and the steps of getting a PDF.

import Foundation

/// What the Suggested section, its details panel and its notification say.
enum SuggestionsPresentation {
    /// The section's title, and the notification's.
    static var windowTitle: String { L("Suggested Papers") }
    /// The File menu item, which shows the section.
    static var menuItem: String { L("Show Suggested Papers") }
    /// The sidebar row's tooltip.
    static var sidebarHelp: String { L("Papers like yours, from Semantic Scholar") }

    // MARK: Header

    static var enableToggle: String { L("Check every day") }
    /// The switch's tooltip, and the empty list's text: what a check sends where, since it's off until turned on.
    static var enableHelp: String {
        L("Once a day, Papertalk sends the DOIs of the papers in your library to Semantic Scholar and lists papers like them here. Your LLM ranks them by how well they fit.")
    }
    static func checkButton(checking: Bool) -> String { checking ? L("Checking…") : L("Check Now") }
    /// Check Now works without the switch (a one-off check), but not twice at once.
    static func canCheck(checking: Bool) -> Bool { !checking }

    /// "Last checked 20 Nov 2026 at 09:14", or that it never ran: the section's subtitle.
    static func lastChecked(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return L("Not checked yet") }
        return L("Last checked {0}", date.formatted(date: .abbreviated, time: .shortened))
    }

    // MARK: Results of a check

    static var noSeeds: String {
        L("Suggestions start from your papers' DOIs, and none of your papers has one. Add a DOI with Edit paper first.")
    }
    static func checkFailed(_ reason: String) -> String { L("Couldn't check for suggested papers: {0}", reason) }
    /// The status line, and the notification's text.
    static func found(_ n: Int) -> String {
        switch n {
        case 0: return L("No new papers this time.")
        case 1: return L("1 new paper like yours.")
        default: return L("{0} new papers like yours.", n)
        }
    }
    /// The toast after a check found papers.
    static func foundToast(_ n: Int) -> String {
        n == 1 ? L("1 new suggested paper. See it under Suggested Papers in the sidebar.")
            : L("{0} new suggested papers. See them under Suggested Papers in the sidebar.", n)
    }

    // MARK: List

    static var emptyTitle: String { L("No suggested papers") }
    static func emptyMessage(enabled: Bool) -> String {
        enabled ? L("New suggestions appear here after the daily check. Check Now looks right away.")
            : L("Turn on Check every day above, or use Check Now once.")
    }

    /// "A. Vaswani, N. Shazeer, N. Parmar et al. · 2017 · Semantic Scholar".
    static func details(_ s: Suggestion) -> String {
        let authors = s.authors.count > 3 ? L("{0} et al.", s.authors.prefix(3).joined(separator: ", "))
            : s.authors.joined(separator: ", ")
        return [authors, s.year.map(String.init) ?? "", source(s.source)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func source(_ s: Suggestion.Source) -> String {
        switch s {
        case .semanticScholar: return L("Semantic Scholar")
        case .scholarAlert: return L("Google Scholar alert")
        }
    }

    /// Whether Import gets the PDF alone or needs the browser.
    static func availability(_ s: Suggestion) -> String { s.pdfURL == nil ? L("Download in browser") : L("Free PDF") }
    static func availabilityHelp(_ s: Suggestion) -> String {
        s.pdfURL == nil ? L("Papertalk opens the paper's page; you download the PDF and it's picked up from Downloads.")
            : L("Papertalk downloads the PDF itself.")
    }
    static func availabilityIcon(_ s: Suggestion) -> String { s.pdfURL == nil ? "safari" : "arrow.down.doc" }
    /// The free-PDF badge is tinted; the browser one is plain.
    static func isFree(_ s: Suggestion) -> Bool { s.pdfURL != nil }

    /// Where a suggestion is in the imports.
    enum RowState: Equatable { case idle, queued, fetching }

    static func rowState(_ id: String, fetch: PaperFetch?) -> RowState {
        guard let fetch else { return .idle }
        if fetch.current.id == id { return .fetching }
        return fetch.queue.contains { $0.id == id } ? .queued : .idle
    }
    /// What a row says in place of its buttons while it's being imported; nil when idle.
    static func rowStatus(_ state: RowState) -> String? {
        switch state {
        case .idle: return nil
        case .queued: return L("Queued")
        case .fetching: return L("Importing…")
        }
    }
    /// Import and Dismiss are offered only while a row isn't being imported.
    static func canAct(_ state: RowState) -> Bool { state == .idle }

    static var importButton: String { L("Import") }
    static var importHelp: String { L("Import this paper with the depth of your last import") }
    static var dismissButton: String { L("Dismiss") }
    static var dismissHelp: String { L("Hide this paper for good") }
    static var openPageButton: String { L("Open in Browser") }
    /// "Imported as: Summary": the depth the last import sheet used.
    static func importsWith(_ choice: ImportChoice) -> String { L("Imported as: {0}", choice.resolvedDepth.label) }

    // MARK: Details panel

    static var noSelectionTitle: String { L("No suggestion selected") }
    static var noSelectionMessage: String { L("Pick a suggested paper to read its abstract and why it fits your library.") }
    static var whyTitle: String { L("Why it fits") }
    static var abstractTitle: String { L("Abstract") }
    static func abstract(_ s: Suggestion) -> String {
        let text = (s.abstract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L("Semantic Scholar has no abstract for this paper. Open it in the browser to read more.") : text
    }
    /// Every author, in byline order.
    static func authors(_ s: Suggestion) -> String { s.authors.joined(separator: ", ") }
    /// "DOI 10.1/x", or nil without one.
    static func doiLine(_ s: Suggestion) -> String? { s.doi.map { L("DOI {0}", $0) } }

    // MARK: Getting the paper

    /// "Paper 2 of 3".
    static func position(_ f: PaperFetch) -> String { L("Paper {0} of {1}", f.position, f.total) }
    static func heading(_ f: PaperFetch) -> String { L("Getting “{0}”", f.current.title) }

    /// The steps shown while waiting for the user's download.
    static var browserSteps: [String] {
        [L("Open the paper's page in your browser."),
         L("Download the PDF (sign in through your library or institution if the page asks)."),
         L("Papertalk picks up the new PDF from your Downloads folder and imports it.")]
    }

    static func status(_ f: PaperFetch) -> String {
        switch f.step {
        case .downloading: return L("Downloading the free PDF…")
        case .waiting: return L("Waiting for a new PDF in Downloads…")
        case .importing(let name): return L("Found “{0}”. Importing…", name)
        }
    }

    /// Only the wait needs the browser (and a page to open).
    static func showsBrowserSteps(_ f: PaperFetch) -> Bool { f.step == .waiting }
    static func canOpenPage(_ s: Suggestion) -> Bool { s.pageURL != nil }
    static var skipButton: String { L("Skip") }
    static var skipHelp: String { L("Leave this paper in the list and go to the next.") }
    static var stopButton: String { L("Stop") }

    /// The toast when a downloaded PDF doesn't look like the paper it was meant to be.
    static func mismatch(file: String, title: String) -> String {
        L("“{0}” doesn't look like “{1}”. It was imported anyway; delete it if it's the wrong paper.", file, title)
    }
}
