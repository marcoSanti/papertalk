// Baked episode audio: what import-time voicing saves (one WAV per turn and a manifest of
// their durations) and what the player loads back.

import Foundation

/// The rendered WAV for a single turn, plus its runtime duration.
struct BakedTurn {
    /// 24 kHz mono 16-bit WAV (see `SpeechAudio.normalizedWAV`).
    let wav: Data
    /// Seconds, measured from the WAV.
    let duration: Double
}

/// Manifest of a baked episode: one WAV per turn, saved under the paper's
/// `turns/` subpath. Durations let the player rebuild timing without touching
/// the model.
struct AudioManifest: Codable {
    /// One entry per turn, in script order; turn `i` is stored at `K.turn(id, i)`.
    var durations: [Double]
}