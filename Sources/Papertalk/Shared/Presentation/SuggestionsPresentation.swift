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
    static var sidebarHelp: String { L("Papers like yours, from Semantic Scholar and your Google Scholar alerts") }
    /// The Google Scholar tab's button to Settings → Suggested Papers, shown until alerts are read.
    static var setUpAlertsButton: String { L("Set Up Scholar Alerts…") }
    static var setUpAlertsHelp: String {
        L("Opens Settings → Suggested Papers, to also read the papers in your Google Scholar alert emails.")
    }
    static var alertsNotSetUpTitle: String { L("Google Scholar alerts aren't set up") }
    static var alertsNotSetUpMessage: String {
        L("Papertalk can add the papers from your Google Scholar alert emails here. Tell it which mail account they arrive in.")
    }

    // MARK: Tabs

    /// One tab per source, so the two lists aren't mixed.
    static let tabs: [Suggestion.Source] = [.semanticScholar, .scholarAlert]
    /// "Semantic Scholar (4)".
    static func tabLabel(_ tab: Suggestion.Source, count: Int) -> String {
        L("{0} ({1})", tab == .semanticScholar ? L("Semantic Scholar") : L("Google Scholar alerts"), count)
    }
    /// The pending suggestions from one source, in their ranked order.
    static func pending(_ all: [Suggestion], in tab: Suggestion.Source) -> [Suggestion] { all.filter { $0.source == tab } }
    /// An empty Google Scholar tab invites setting alerts up until they're read.
    static func showsAlertSetup(tab: Suggestion.Source, ready: Bool) -> Bool { tab == .scholarAlert && !ready }

    // MARK: Header

    static var enableToggle: String { L("Check every day") }
    /// The switch's tooltip, and the empty list's text: what a check sends where, since it's off until turned on.
    static var enableHelp: String {
        L("Once a day, Papertalk sends the DOIs of the papers in your library to Semantic Scholar, reads your Google Scholar alert emails if you set them up, and lists the papers here. Your LLM ranks them by how well they fit.")
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
        L("Suggestions start from your papers' DOIs or your Google Scholar alert emails, and there are neither yet. Add a DOI with Edit paper, or click Set Up Scholar Alerts… to read your alert emails.")
    }
    static func checkFailed(_ reason: String) -> String { L("Couldn't check for suggested papers: {0}", reason) }
    /// Why the alert emails couldn't be read, as one of a check's failures.
    static func alertsFailed(_ reason: String) -> String { L("Google Scholar alerts: {0}", reason) }
    /// After a check that got an answer: how many arrived, and what failed alongside.
    static func checkResult(added: Int, failures: [String]) -> String {
        failures.isEmpty ? found(added) : found(added) + " " + checkFailed(failures.joined(separator: " "))
    }
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
            : L("Turn on Check every day in Settings → Suggested Papers, or use Check Now once.")
    }

    /// "A. Vaswani, N. Shazeer, N. Parmar et al. · 2017" (the source has its own badge).
    static func details(_ s: Suggestion) -> String {
        let authors = PaperPresentation.authorLine(s.authors)
        return [authors, s.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The source badge's SF Symbol: a mail for alerts, a magnifier for Semantic Scholar's search.
    static func sourceIcon(_ s: Suggestion.Source) -> String {
        switch s {
        case .semanticScholar: return "magnifyingglass"
        case .scholarAlert: return "envelope"
        }
    }

    /// The source badge's tooltip: why this paper is here.
    static func sourceHelp(_ s: Suggestion.Source) -> String {
        switch s {
        case .semanticScholar: return L("Recommended by Semantic Scholar, from the papers in your library")
        case .scholarAlert: return L("From one of your Google Scholar alert emails")
        }
    }

    static func source(_ s: Suggestion.Source) -> String {
        switch s {
        case .semanticScholar: return L("Semantic Scholar")
        case .scholarAlert: return L("Google Scholar alert")
        }
    }

    /// Whether Import gets the PDF alone or needs the browser.
    static func availability(_ s: Suggestion) -> String { isFree(s) ? L("Free PDF") : L("Download in browser") }
    static func availabilityHelp(_ s: Suggestion) -> String {
        isFree(s) ? L("Papertalk downloads the PDF itself.")
            : L("Papertalk opens the paper's page; you download the PDF and it's picked up from Downloads.")
    }
    static func availabilityIcon(_ s: Suggestion) -> String { isFree(s) ? "arrow.down.doc" : "safari" }
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
    /// With libraries, Import is a menu asking which one the paper goes in (like the import sheet).
    static func asksLibrary(_ libraries: [Library]) -> Bool { !libraries.isEmpty }
    static var libraryMenuTitle: String { L("Add to library") }
    static var noLibrary: String { L("No Library") }
    static var importHelp: String { L("Import this paper with the depth of your last import") }
    static var dismissButton: String { L("Dismiss") }
    static var dismissHelp: String { L("Hide this paper for good") }
    static var openPageButton: String { L("Open in Browser") }
    /// The header's depth menu.
    static var importDepthLabel: String { L("Import as") }
    static var importDepthHelp: String {
        L("How suggested papers are written. It starts as your last import's depth; Summary uses that import's length.")
    }
    /// The menu's depths: the ones that need nothing typed, plus Custom when it's the current one
    /// (from the import sheet, with its description).
    static func importDepths(current: Depth) -> [Depth] {
        [.inDepth, .summary, .direct] + (current == .custom ? [.custom] : [])
    }

    // MARK: Details panel

    static var noSelectionTitle: String { L("No suggestion selected") }
    static var noSelectionMessage: String { L("Pick a suggested paper to read its abstract and why it fits your library.") }
    static var whyTitle: String { L("Why it fits") }
    static var abstractTitle: String { L("Abstract") }
    static func abstract(_ s: Suggestion) -> String {
        let text = (s.abstract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        switch s.source {
        case .semanticScholar: return L("Semantic Scholar has no abstract for this paper. Open it in the browser to read more.")
        case .scholarAlert: return L("The alert email has no abstract for this paper. Open it in the browser to read more.")
        }
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
