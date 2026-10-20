import Foundation

enum Depth: String, CaseIterable, Identifiable {
    case inDepth = "in_depth", summary, direct, custom
    var id: String { rawValue }
    var label: String { switch self {
        case .inDepth: "In-depth"
        case .summary: "Summary"
        case .custom: "Custom"
        case .direct: "Direct read"
    } }
    var blurb: String { switch self {
        case .inDepth: "Full technical detail; method sections are read through faithfully. As long as the paper needs."
        case .summary: "High-level overview; nothing read verbatim, easier to follow. You choose the length."
        case .custom: "Describe the depth you want."
        case .direct: "Read the extracted text out loud as-is. No LLM rewriting — only text-extraction fixes."
    } }
}

/// How long a summary episode may run, chosen on the import sheet.
enum SummaryLength {
    static let range = 5...60
    static let step = 5
    static let defaultMinutes = 35

    /// Into the range, on a whole step.
    static func clamped(_ minutes: Double) -> Int {
        let stepped = Int((minutes / Double(step)).rounded()) * step
        return min(range.upperBound, max(range.lowerBound, stepped))
    }

    static func label(_ minutes: Int) -> String { "Up to \(minutes) minutes" }
}
