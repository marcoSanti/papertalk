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
        case .summary: "High-level overview; nothing read verbatim, easier to follow. Up to about 35 minutes."
        case .custom: "Describe the depth you want."
        case .direct: "Read the extracted text out loud as-is. No LLM rewriting — only text-extraction fixes."
    } }
}