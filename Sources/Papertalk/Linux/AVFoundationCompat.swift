// Linux stand-in for AVFoundation's AVAudioPlayer: plays a WAV by piping its PCM to the
// desktop's sound server.

#if os(Linux)
import Foundation

// AVAudioPlayer as far as PlayerController uses it, so the player is unchanged
// on Linux. Playback streams the WAV's PCM to the desktop's sound server
// through its command-line player (PipeWire, PulseAudio or ALSA). It stays in
// Swift rather than Python: the Python thread can be busy synthesising for
// seconds, and play/pause must not wait for it.

/// Called on the main thread, as AVFoundation does.
@MainActor
protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
}

/// One sound, played through a sound-server process; pausing stops the process and remembers
/// the position.
final class AVAudioPlayer {
    /// The data wasn't a WAV this player can stream.
    struct FormatError: LocalizedError {
        var errorDescription: String? { "The audio isn't a 16-bit PCM WAV file." }
    }

    /// Told when the sound plays to its end.
    weak var delegate: AVAudioPlayerDelegate?
    /// Seconds of audio.
    let duration: Double

    private let pcm: Data
    private let sampleRate: Int
    private let channels: Int
    private var bytesPerSecond: Int { sampleRate * channels * 2 }

    private var sink: Process?
    private var startedAt: Date?
    private var offset: Double = 0
    private var finish: DispatchWorkItem?

    /// A player for a 16-bit PCM WAV; throws `FormatError` for anything else.
    init(data: Data) throws {
        guard let wav = WAV(data) else { throw FormatError() }
        pcm = wav.pcm
        sampleRate = wav.sampleRate
        channels = wav.channels
        duration = Double(pcm.count) / Double(wav.sampleRate * wav.channels * 2)
    }

    /// A sound-server process is running.
    var isPlaying: Bool { sink != nil }

    /// Seconds into the sound, from the clock (the sound server's buffer makes
    /// the real position lag by a few milliseconds).
    var currentTime: Double {
        get { min(duration, offset + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)) }
        set {
            let resume = isPlaying
            halt()
            offset = max(0, min(newValue, duration))
            if resume { play() }
        }
    }

    /// Nothing to prepare: kept for API compatibility.
    @discardableResult
    func prepareToPlay() -> Bool { true }

    /// Start (or resume) from the current position; false when no player program is available.
    @discardableResult
    func play() -> Bool {
        guard sink == nil else { return true }
        guard offset < duration, let command = Self.sinkCommand(rate: sampleRate, channels: channels) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        sink = process
        startedAt = Date()

        // Whole frames from the current offset, written off the main thread.
        let frameBytes = channels * 2
        let start = min(pcm.count, Int(offset * Double(bytesPerSecond)) / frameBytes * frameBytes)
        let chunk = pcm.subdata(in: start..<pcm.count)
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: chunk)   // fails harmlessly if paused (SIGPIPE ignored)
            try? writer.close()
        }

        let done = DispatchWorkItem { [weak self] in
            guard let self, self.sink === process else { return }
            self.halt()
            self.offset = self.duration
            MainActor.assumeIsolated { self.delegate?.audioPlayerDidFinishPlaying(self, successfully: true) }
        }
        finish = done
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration - offset), execute: done)
        return true
    }

    /// Stop the sound, keeping the position.
    func pause() {
        let now = currentTime
        halt()
        offset = now
    }

    /// As `pause`: the player is thrown away after stopping anyway.
    func stop() { pause() }

    /// Kill the sound-server process and cancel the end-of-sound callback.
    private func halt() {
        finish?.cancel(); finish = nil
        if let sink, sink.isRunning { sink.terminate() }
        sink = nil
        startedAt = nil
    }

    // MARK: - Sound server

    /// The first available player reading raw s16le PCM from stdin.
    /// PAPERTALK_AUDIO_SINK overrides it (a shell command, used by tests).
    static func sinkCommand(rate: Int, channels: Int) -> [String]? {
        Self.ignoreSIGPIPE
        if let custom = ProcessInfo.processInfo.environment["PAPERTALK_AUDIO_SINK"] {
            return ["sh", "-c", custom]
        }
        let candidates: [(String, [String])] = [
            ("pw-cat", ["--playback", "--rate", "\(rate)", "--channels", "\(channels)", "--format", "s16", "-"]),
            ("paplay", ["--raw", "--rate=\(rate)", "--channels=\(channels)", "--format=s16le"]),
            ("aplay", ["-q", "-t", "raw", "-f", "S16_LE", "-r", "\(rate)", "-c", "\(channels)"]),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for (tool, args) in candidates {
            if path.split(separator: ":").contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }) {
                return [tool] + args
            }
        }
        return nil
    }

    /// Writing to a player that was just stopped must not kill the app.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()
}

/// The parts of a PCM WAV file the player needs.
struct WAV {
    /// Samples per second.
    let sampleRate: Int
    /// Interleaved channels.
    let channels: Int
    /// The `data` chunk: 16-bit little-endian samples.
    let pcm: Data

    /// nil unless it's 16-bit PCM.
    init?(_ data: Data) {
        guard SpeechAudio.isWAV(data), let wav = try? SpeechAudio.parseWAV(data),
              wav.format == 1, wav.bits == 16 else { return nil }
        (sampleRate, channels, pcm) = (Int(wav.rate), wav.channels, wav.samples)
    }
}
#endif
