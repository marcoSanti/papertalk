import Foundation

// MARK: - Paper (library record) — mirrors /api/library entries
struct Paper: Identifiable, Codable, Equatable {
    var id: String
    var title: String?
    var filename: String?
    var hasPdf: Bool
    var hasScript: Bool
    var hasAudio: Bool
    var createdIso: String?
    var state: String
    var tags: [String]
    var favorite: Bool
    var authors: [String]
    var affiliations: [String]
    var doi: String
    var read: Bool
    var depth: String?
    var progress: Double
    var duration: Double
    var progressTs: String?
    var stage: String?
    var message: String?
    var statusError: String?

    enum CodingKeys: String, CodingKey {
        case id, title, filename, tags, favorite, authors, affiliations, doi, read, depth
        case hasPdf = "has_pdf", hasScript = "has_script", hasAudio = "has_audio"
        case createdIso = "created_iso", state, progress, duration
        case progressTs = "progress_ts", stage, message
        case statusError = "status_error"
    }

    var displayTitle: String { title?.trimmedNotEmpty ?? filename ?? "Untitled" }
    var isActive: Bool { ["running", "queued", "awaiting_audio"].contains(state) }
    var isDone: Bool { state == "done" }
    var isError: Bool { state == "error" }

    /// Which status row class to render against.
    var statusKind: StatusKind { isActive ? .running : isError ? .error : isDone ? .done : .unknown }

    /// A copy with the error state cleared and progress reset, ready to retry.
    func revertingError() -> Paper {
        var p = self
        p.state = "running"
        p.stage = "extract"
        p.message = "Retrying…"
        p.statusError = nil
        p.progress = 0.02
        return p
    }
}

enum StatusKind: String { case running, done, error, unknown }

extension Paper {
    var depthTitle: String? {
        guard let d = depth else { return nil }
        return Depth(rawValue: d)?.label
    }
}

private extension String {
    var trimmedNotEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}