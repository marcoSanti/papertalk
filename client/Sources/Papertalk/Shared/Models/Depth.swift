// Episode depth (how much of the paper the LLM covers) and the summary length setting,
// as chosen on the import sheet and saved on each paper for reruns.

import Foundation

/// How the paper is turned into an episode. The raw value is saved as `Paper.depth`.
enum Depth: String, CaseIterable, Identifiable {
    case inDepth = "in_depth", summary, direct, custom
    var id: String { rawValue }
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

/// How long a summary episode may run, chosen on the import sheet.
enum SummaryLength {
    /// Minutes a summary may be set to, in steps of `step`.
    static let range = 5...60
    static let step = 5
    /// The slider's starting point, and the length of summaries saved without one.
    static let defaultMinutes = 35

    /// Into the range, on a whole step.
    static func clamped(_ minutes: Double) -> Int {
        let stepped = Int((minutes / Double(step)).rounded()) * step
        return min(range.upperBound, max(range.lowerBound, stepped))
    }

    /// "Up to 35 minutes", beside the length slider.
    static func label(_ minutes: Int) -> String { L("Up to {0} minutes", minutes) }
}
