import Foundation

enum Depth: String, CaseIterable, Identifiable {
    case inDepth = "in_depth", summary, custom
    var id: String { rawValue }
    var label: String { switch self {
        case .inDepth: "In-depth"
        case .summary: "Summary"
        case .custom: "Custom"
    } }
    var blurb: String { switch self {
        case .inDepth: "Full technical detail; method sections are read through faithfully."
        case .summary: "High-level overview; nothing read verbatim, easier to follow."
        case .custom: "Describe the depth you want."
    } }
}