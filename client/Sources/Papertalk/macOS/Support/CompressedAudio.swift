// Decoding compressed speech audio on macOS (Linux has its own in `Linux/CompressedAudioCompat`).

#if os(macOS)
import AVFoundation
import Foundation

/// Decodes compressed audio (MP3, AAC, FLAC, …) a speech server may send
/// instead of WAV, through AVFoundation. `SpeechAudio` resamples the result.
enum CompressedAudio {
    /// Mono samples in -1…1 at the file's own rate; throws when AVFoundation can't read it.
    static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        // AVAudioFile reads from a file, and picks the decoder partly by extension.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("papertalk-speech-\(UUID().uuidString).\(fileExtension(data))")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw SpeechAudio.Failure.unreadable
            }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else { throw SpeechAudio.Failure.unreadable }
            let frames = Int(buffer.frameLength), count = Int(format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<count {
                for f in 0..<frames { mono[f] += channels[c][f] / Float(count) }
            }
            return (mono, format.sampleRate)
        } catch let failure as SpeechAudio.Failure {
            throw failure
        } catch {
            throw SpeechAudio.Failure.unreadable
        }
    }

    /// An extension AVAudioFile recognizes, guessed from the magic bytes.
    private static func fileExtension(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: Array("fLaC".utf8)) { return "flac" }
        if head.starts(with: Array("OggS".utf8)) { return "ogg" }
        if head.count >= 8, Array(head[4..<8]) == Array("ftyp".utf8) { return "m4a" }
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xF6 == 0xF0 { return "aac" }
        return "mp3"
    }
}
#endif
