#if os(Linux)
import Foundation

/// No compressed-audio decoder on Linux: speech servers must return WAV
/// (Papertalk asks for it), and anything else gets a plain error.
enum CompressedAudio {
    static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        throw SpeechAudio.Failure.compressedUnsupported
    }
}
#endif
