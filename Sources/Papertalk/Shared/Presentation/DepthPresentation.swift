// How depths and summary lengths are worded.

import Foundation

extension Depth {
    /// The choice's name on the import sheet.
    var label: String { switch self {
        case .inDepth: L("In-depth")
        case .summary: L("Summary")
        case .custom: L("Custom")
        case .direct: L("Direct read")
    } }
    /// One-line explanation under the name on the import sheet.
    var blurb: String { switch self {
        case .inDepth: L("Full technical detail; method sections are read through faithfully. As long as the paper needs.")
        case .summary: L("High-level overview; nothing read verbatim, easier to follow. You choose the length.")
        case .custom: L("Describe the depth you want.")
        case .direct: L("Read the extracted text out loud as-is. No LLM rewriting — only text-extraction fixes.")
    } }
}

extension SummaryLength {
    /// "Up to 35 minutes", beside the length slider.
    static func label(_ minutes: Int) -> String { L("Up to {0} minutes", minutes) }
}

extension Paper {
    /// The depth's name, for card subtitles.
    var depthTitle: String? {
        guard let d = depth else { return nil }
        return Depth(rawValue: d)?.label
    }
}
