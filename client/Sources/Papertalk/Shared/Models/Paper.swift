// The library record of one paper (`paper.json`) and the cast types around it: the speakers
// the LLM proposes and the names and voices the user confirms.

import Foundation

/// One participant in a podcast: the name used in the transcript and the
/// Kokoro voice (id) they speak in. Persisted per paper so baked and live
/// audio always use the user's chosen voices.
struct SpeakerConfig: Codable, Equatable, Hashable {
    /// The name as it appears in the transcript's turns.
    var name: String
    /// A Kokoro voice id, e.g. "af_heart".
    var voice: String
}

/// A cast member the LLM proposes for an episode before the user confirms
/// names and voices. `voice` defaults to the gender's canonical Kokoro voice.
struct ProposedSpeaker: Equatable, Hashable {
    /// The LLM's role label, e.g. "Interviewer" or "Scientist" (see `CastForm.isHost`).
    var role: String
    /// "male" / "female", or nil when neither the LLM nor the name tells.
    var gender: String?
    var name: String
    var voice: String

    /// Takes the default voice for `gender`; `CastForm` picks distinct ones.
    init(role: String, gender: String?, name: String) {
        self.role = role
        self.gender = gender
        self.name = name
        self.voice = KokoroSpeech.defaultVoice(forGender: gender)
    }

    /// What gets saved on the paper once confirmed.
    var asConfig: SpeakerConfig { SpeakerConfig(name: name, voice: voice) }
}

/// The LLM's casting answer: who speaks, plus the gender of every author so
/// the sheet can re-voice the guest when the user picks a different author.
struct CastProposal {
    /// Interviewer first, then the guest.
    var speakers: [ProposedSpeaker]
    /// Author full name (as in `Paper.authors`) -> "male" / "female".
    var authorGenders: [String: String]
}

// MARK: - Paper (library record)

/// Everything the library knows about a paper. Saved with synthesized `Codable`, so every
/// property added later must be optional (or old records fail to decode and vanish).
struct Paper: Identifiable, Codable, Equatable {
    /// A UUID, also the name of the paper's folder (`K.folder(id)`).
    var id: String
    /// From the metadata step or typed by the user; nil until then (see `displayTitle`).
    var title: String?
    /// The imported PDF's file name; editable, shown in list rows.
    var filename: String?
    /// `source.pdf` is stored.
    var hasPdf: Bool
    /// `transcript.json` is stored (the episode can be read, and played live).
    var hasScript: Bool
    /// Every turn's audio is baked (the episode plays from disk).
    var hasAudio: Bool
    /// When it was imported (ISO 8601).
    var createdIso: String?
    /// When it was published, from Crossref (YYYY, YYYY-MM or YYYY-MM-DD); nil when unknown.
    var publishedIso: String?
    /// "queued", "running", "done", "error" or "draft" (see `isActive` and `statusKind`).
    var state: String
    /// Topic tags; spaces are stored as underscores.
    var tags: [String]
    /// Starred (the Favorites section).
    var favorite: Bool
    /// Full names in byline order.
    var authors: [String]
    var affiliations: [String]
    /// Bare DOI, or empty.
    var doi: String
    /// Listened to the end (or marked so); clears the NEW badge.
    var read: Bool
    /// A `Depth` raw value; nil in very old records (treated as in-depth).
    var depth: String?
    /// The citation from doi2bib, once the DOI resolved.
    var bibtex: String?
    /// Persisted under "speakers". Optional so paper.json files written before
    /// the cast step existed still decode.
    var storedSpeakers: [SpeakerConfig]? = nil
    /// Summary only: the longest the episode may run, in minutes (nil: the
    /// default, `SummaryLength.defaultMinutes`). Kept so reruns match.
    var targetMinutes: Int? = nil
    /// Whether `mindmap.json` was written (nil in records from before mind maps).
    var hasMindMap: Bool? = nil
    /// The language the LLM writes the episode in (an `AppLanguage` raw value);
    /// nil is English, the default. Kept so reruns match.
    var scriptLanguage: String? = nil
    /// While converting, the progress bar's fraction (0…1); once done, the playback position in seconds.
    var progress: Double
    /// The episode's length in seconds, once it has been played or baked.
    var duration: Double
    /// Unused; kept so older records keep the field.
    var progressTs: String?
    /// The pipeline step in progress (see `ConversionPresentation.stages`).
    var stage: String?
    /// The progress line under the bar, in the interface language of the moment.
    var message: String?
    /// Why the last conversion failed or stopped; nil when it didn't.
    var statusError: String?

    enum CodingKeys: String, CodingKey {
        case id, title, filename, tags, favorite, authors, affiliations, doi, read, depth, bibtex
        case hasPdf = "has_pdf", hasScript = "has_script", hasAudio = "has_audio"
        case createdIso = "created_iso", state, progress, duration
        case publishedIso = "published_iso"
        case progressTs = "progress_ts", stage, message
        case statusError = "status_error"
        case storedSpeakers = "speakers"
        case targetMinutes = "target_minutes"
        case hasMindMap = "has_mind_map"
        case scriptLanguage = "script_language"
    }

    /// The episode's cast (names + chosen voices); empty when never set.
    var speakers: [SpeakerConfig] {
        get { storedSpeakers ?? [] }
        set { storedSpeakers = newValue.isEmpty ? nil : newValue }
    }

    /// The title, else the filename: what lists and alerts show.
    var displayTitle: String { title?.trimmedNotEmpty ?? filename ?? "Untitled" }
    /// Being converted, or waiting its turn to be.
    var isActive: Bool { ["running", "queued", "awaiting_audio"].contains(state) }
    /// Converted (with or without audio).
    var isDone: Bool { state == "done" }
    /// The last conversion failed or was stopped.
    var isError: Bool { state == "error" }

    /// Which status row class to render against.
    var statusKind: StatusKind { isActive ? .running : isError ? .error : isDone ? .done : .unknown }

    /// A copy with the error acknowledged: back to "done" when an earlier
    /// episode is still on disk, otherwise an unconverted "draft".
    func dismissingError() -> Paper {
        var p = self
        if hasScript {
            p.state = "done"; p.stage = "done"; p.progress = 1; p.message = L("Done")
        } else {
            p.state = "draft"; p.stage = nil; p.progress = 0; p.message = nil
        }
        p.statusError = nil
        return p
    }
}

/// The status a paper is drawn with in lists and badges.
enum StatusKind: String { case running, done, error, unknown }

extension Paper {
    /// The progress stage of a mind map being drawn.
    static let mindMapStage = "mindmap"

    /// The language the LLM writes this paper's episode in.
    var episodeLanguage: AppLanguage { scriptLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english }

    /// The depth's name, for card subtitles.
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