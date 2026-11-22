// Episode depth (how much of the paper the LLM covers) and the summary length setting,
// as chosen on the import sheet and saved on each paper for reruns.

import Foundation

/// How the paper is turned into an episode. The raw value is saved as `Paper.depth`.
enum Depth: String, CaseIterable, Identifiable {
    case inDepth = "in_depth", summary, direct, custom
    var id: String { rawValue }
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
}
