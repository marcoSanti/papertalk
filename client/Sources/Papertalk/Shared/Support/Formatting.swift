import Foundation

/// mm:ss for playhead / duration values; "–:––" when not finite.
func formatT(_ s: Double) -> String {
    guard s.isFinite else { return "–:––" }
    let m = Int(s) / 60, sec = Int(s) % 60
    return "\(m):" + String(format: "%02d", sec)
}

/// Friendly label for a pipeline stage, shown in import progress bars.
func stageLabel(_ stage: String) -> String {
    switch stage {
    case "extract": return L("Extracting text from PDF")
    case "notes": return L("Summarizing paper")
    case "outline": return L("Planning episode")
    case "segments": return L("Writing dialogue")
    case "audio": return L("Synthesizing audio")
    case Paper.mindMapStage: return L("Drawing mind map")
    case "finalize": return L("Finalizing")
    default: return stage.isEmpty ? L("Processing…") : stage.capitalized + "…"
    }
}

/// ISO8601 string -> short date. Handles full timestamps, plus the partial
/// calendar dates Crossref returns (YYYY, YYYY-MM, YYYY-MM-DD).
func formatDate(_ iso: String) -> String {
    let full = ISO8601DateFormatter()
    if let d = full.date(from: iso) {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        df.locale = Localization.language.locale
        return df.string(from: d)
    }
    let parse = DateFormatter()
    parse.locale = Locale(identifier: "en_US_POSIX")
    parse.calendar = Calendar(identifier: .gregorian)
    let out = DateFormatter()
    out.locale = Localization.language.locale
    out.calendar = Calendar(identifier: .gregorian)
    switch iso.count {
    case 0...4: parse.dateFormat = "yyyy"; out.dateFormat = "yyyy"
    case 5...7: parse.dateFormat = "yyyy-MM"; out.dateFormat = "MMMM yyyy"
    default: parse.dateFormat = "yyyy-MM-dd"; out.dateStyle = .medium; out.timeStyle = .none
    }
    guard let d = parse.date(from: iso) else { return "" }
    return out.string(from: d)
}
/// How the app refers to the machine it runs on, in user-facing copy.
enum Device {
    #if os(Linux)
    static var this: String { L("this computer") }
    /// The machine as a choice or a place, e.g. the storage options.
    static var thisTitle: String { L("This computer") }
    static var on: String { L("On this computer") }
    #else
    static var this: String { L("this Mac") }
    static var thisTitle: String { L("This Mac") }
    static var on: String { L("On this Mac") }
    #endif
}
