import Foundation

/// The rendered WAV for a single turn, plus its runtime duration.
struct BakedTurn {
    let wav: Data
    let duration: Double
}

/// Manifest of a baked episode: one WAV per turn, saved under the paper's
/// `turns/` subpath. Durations let the player rebuild timing without touching
/// the model.
struct AudioManifest: Codable {
    var durations: [Double]
}