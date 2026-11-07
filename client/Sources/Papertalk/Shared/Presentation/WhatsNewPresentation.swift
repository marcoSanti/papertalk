// The "What's new" screen shown once after an update: its entries, parsed from the CHANGELOG.md
// lines `app.sh` embeds in the app, and when to show them.

import Foundation

/// What a build changed, as the sheet lists it.
struct WhatsNew: Identifiable, Equatable {
    /// One line of the changelog: `- <emoji> **Title**: description`.
    struct Item: Equatable {
        var emoji: String
        var title: String
        var detail: String
    }

    /// The sheet's heading ("What's new in Papertalk 0.7.0").
    let title: String
    let items: [Item]
    var id: String { title }

    /// The entries of `notes`; lines that don't follow the form are skipped.
    static func parse(_ notes: String) -> [Item] {
        let pattern = #"^-\s+(\S+)\s+\*\*(.+?)\*\*:?\s*(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return notes.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return Item(emoji: ns.substring(with: m.range(at: 1)), title: ns.substring(with: m.range(at: 2)),
                        detail: ns.substring(with: m.range(at: 3)))
        }
    }

    /// The screen for `build`, or nil when it has no entries or they're the ones `seen` last.
    /// A first launch (`onboarded` false) shows nothing: the user hasn't updated from anything.
    static func toShow(for build: AppBuild, seen: String?, onboarded: Bool) -> WhatsNew? {
        guard onboarded, let notes = build.whatsNew, notes != seen else { return nil }
        let items = parse(notes)
        guard !items.isEmpty else { return nil }
        return WhatsNew(title: L("What's new in Papertalk {0}", build.version ?? ""), items: items)
    }
}
