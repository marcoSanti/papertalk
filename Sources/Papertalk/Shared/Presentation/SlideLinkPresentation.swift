// Wording and rules for the link between a slide deck and the paper it presents: the deck's
// Paper card (pick, open, unlink) and the paper's Slides card (its decks).

import Foundation

/// The detail pane's link card, for a deck or for a paper with linked decks.
enum SlideLinkPresentation {
    /// A deck always has the card (to link it); a paper only when decks are linked to it.
    static func showsCard(_ p: Paper, linkedDecks: [Paper]) -> Bool { p.isSlides || !linkedDecks.isEmpty }
    /// The card's heading: a deck links to its paper, a paper lists its slides.
    static func cardTitle(_ p: Paper) -> String { p.isSlides ? L("Paper") : L("Slides") }
    /// SF Symbol beside the heading.
    static func cardIcon(_ p: Paper) -> String { p.isSlides ? "doc.text" : "rectangle.on.rectangle" }
    /// SF Symbol of a linked item's row.
    static func rowIcon(_ p: Paper) -> String { p.isSlides ? "rectangle.on.rectangle" : "doc.text" }
    /// A linked row's tooltip.
    static func openHelp(_ p: Paper) -> String { p.isSlides ? L("Show this deck in Slides") : L("Show this paper") }
    /// Under the heading of a deck that isn't linked yet; nil once it is.
    static func status(linked: Paper?) -> String? { linked == nil ? L("Not linked to a paper yet.") : nil }
    /// The menu that picks the paper.
    static func menuTitle(linked: Paper?) -> String { linked == nil ? L("Link to a paper…") : L("Change paper…") }
    /// The menu's tooltip: what it does, or why it's off.
    static func menuHelp(hasPapers: Bool) -> String {
        hasPapers ? L("Pick the paper this deck presents") : L("Import the paper first to link it")
    }
    /// The menu's last item, shown once a paper is linked.
    static func showsUnlink(linked: Paper?) -> Bool { linked != nil }
    static var unlink: String { L("Unlink paper") }
}
