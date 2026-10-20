import Foundation

/// Transcript text for the reader sheet and the clipboard.
enum TranscriptPresentation {
    /// Every speaker once, in order of first appearance (declared speakers first).
    static func speakerNames(_ t: Transcript) -> [String] {
        var seen: [String] = []
        for s in t.speakers.map(\.name) + t.segments.flatMap({ $0.turns.map(\.speaker) }) where !seen.contains(s) {
            seen.append(s)
        }
        return seen
    }

    static func segmentCount(_ t: Transcript) -> String {
        LibraryPresentation.count(t.segments.count, L("1 segment"), L("{0} segments"))
    }

    /// "01", "02"… beside each segment title.
    static func segmentNumber(_ index: Int) -> String { String(format: "%02d", index + 1) }

    /// One-letter avatar for a speaker.
    static func speakerInitial(_ name: String) -> String { String(name.prefix(1)).uppercased() }

    /// The whole transcript as plain text: numbered segments, "Speaker: text" turns.
    static func plainText(_ t: Transcript) -> String {
        t.segments.enumerated().map { i, seg in
            "\(i + 1). \(seg.title)\n\n" + seg.turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        }.joined(separator: "\n\n\n")
    }

    /// The activity log pane's text.
    static func logText(_ lines: [String]) -> String {
        lines.isEmpty ? L("No activity yet.") : lines.joined(separator: "\n")
    }
}
