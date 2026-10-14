import Foundation

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