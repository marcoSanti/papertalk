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

// MARK: - Script / transcript
struct Transcript: Codable {
    struct Speaker: Codable, Identifiable {
        var name: String
        var persona: String?
        var id: String { name }
    }
    struct Turn: Codable {
        var speaker: String
        var text: String
    }
    struct Segment: Codable {
        var title: String
        var turns: [Turn]
    }
    var paperTitle: String?
    var speakers: [Speaker]
    var segments: [Segment]
    enum CodingKeys: String, CodingKey {
        case paperTitle = "paper_title", speakers, segments
    }
    init(paperTitle: String? = nil, speakers: [Speaker] = [], segments: [Segment] = []) {
        self.paperTitle = paperTitle
        self.speakers = speakers
        self.segments = segments
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paperTitle = try c.decodeIfPresent(String.self, forKey: .paperTitle)
        speakers = (try? c.decode([Speaker].self, forKey: .speakers)) ?? []
        segments = (try? c.decode([Segment].self, forKey: .segments)) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paperTitle, forKey: .paperTitle)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(segments, forKey: .segments)
    }
}

// MARK: - Helpers
private extension String {
    var trimmedNotEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

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