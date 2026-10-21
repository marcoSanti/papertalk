// The episode script (`transcript.json`): who speaks, and what they say segment by segment.
// Written by the pipeline, read by the player, the transcript sheet and the audio baker.

import Foundation

// MARK: - Script / transcript
/// A whole episode script. Decoding tolerates missing speakers or segments, so a partly
/// written file still opens.
struct Transcript: Codable {
    /// A named voice in the episode. `persona` is "host" or "expert" for LLM-written
    /// episodes, empty for read-throughs.
    struct Speaker: Codable, Identifiable {
        var name: String
        var persona: String?
        var id: String { name }
    }
    /// One line of dialogue: the speaker's name (matching a `Speaker`) and what they say.
    struct Turn: Codable {
        var speaker: String
        var text: String
    }
    /// A titled part of the episode, as planned in the outline.
    struct Segment: Codable {
        var title: String
        var turns: [Turn]
    }
    /// The paper's title as the pipeline saw it; the library uses `Paper.title` instead.
    var paperTitle: String?
    /// Everyone who speaks, interviewer first.
    var speakers: [Speaker]
    /// The episode in order.
    var segments: [Segment]
    enum CodingKeys: String, CodingKey {
        case paperTitle = "paper_title", speakers, segments
    }
    /// An empty or partial script, e.g. for the read-through fallback.
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