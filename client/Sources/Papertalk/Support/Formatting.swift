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
    case "extract": return "Extracting text from PDF"
    case "notes": return "Summarizing paper"
    case "outline": return "Planning episode"
    case "segments": return "Writing dialogue"
    case "audio": return "Synthesizing audio"
    case "finalize": return "Finalizing"
    default: return stage.isEmpty ? "Processing…" : stage.capitalized + "…"
    }
}

/// ISO8601 string -> short date.
func formatDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: iso) {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return df.string(from: d)
    }
    return ""
}