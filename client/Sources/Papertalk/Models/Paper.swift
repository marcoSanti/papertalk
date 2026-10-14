import Foundation

/// One participant in a podcast: the name used in the transcript and the
/// Kokoro voice (id) they speak in. Persisted per paper so baked and live
/// audio always use the user's chosen voices.
struct SpeakerConfig: Codable, Equatable, Hashable {
    var name: String
    var voice: String
}

/// A cast member the LLM proposes for an episode before the user confirms
/// names and voices. `voice` defaults to the gender's canonical Kokoro voice.
struct ProposedSpeaker: Equatable, Hashable {
    var role: String
    var gender: String?
    var name: String
    var voice: String

    init(role: String, gender: String?, name: String) {
        self.role = role
        self.gender = gender
        self.name = name
        self.voice = KokoroSpeech.defaultVoice(forGender: gender)
    }

    var asConfig: SpeakerConfig { SpeakerConfig(name: name, voice: voice) }
}

// MARK: - Paper (library record) — mirrors /api/library entries
struct Paper: Identifiable, Codable, Equatable {
    var id: String
    var title: String?
    var filename: String?
    var hasPdf: Bool
    var hasScript: Bool
    var hasAudio: Bool
    var createdIso: String?
    var publishedIso: String?
    var state: String
    var tags: [String]
    var favorite: Bool
    var authors: [String]
    var affiliations: [String]
    var doi: String
    var read: Bool
    var depth: String?
    var bibtex: String?
    var speakers: [SpeakerConfig] = []
    var progress: Double
    var duration: Double
    var progressTs: String?
    var stage: String?
    var message: String?
    var statusError: String?

    enum CodingKeys: String, CodingKey {
        case id, title, filename, tags, favorite, authors, affiliations, doi, read, depth, bibtex
        case hasPdf = "has_pdf", hasScript = "has_script", hasAudio = "has_audio"
        case createdIso = "created_iso", state, progress, duration
        case publishedIso = "published_iso"
        case progressTs = "progress_ts", stage, message
        case statusError = "status_error"
    }

    var displayTitle: String { title?.trimmedNotEmpty ?? filename ?? "Untitled" }
    var isActive: Bool { ["running", "queued", "awaiting_audio"].contains(state) }
    var isDone: Bool { state == "done" }
    var isError: Bool { state == "error" }

    /// Which status row class to render against.
    var statusKind: StatusKind { isActive ? .running : isError ? .error : isDone ? .done : .unknown }

    /// A copy with the error acknowledged: back to "done" when an earlier
    /// episode is still on disk, otherwise an unconverted "draft".
    func dismissingError() -> Paper {
        var p = self
        if hasScript {
            p.state = "done"; p.stage = "done"; p.progress = 1; p.message = "Done"
        } else {
            p.state = "draft"; p.stage = nil; p.progress = 0; p.message = nil
        }
        p.statusError = nil
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