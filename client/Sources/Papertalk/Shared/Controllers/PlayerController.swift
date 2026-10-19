import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Speaks a paper's transcript using Kokoro neural voices (on-device Core ML /
/// Neural Engine via FluidAudio, or a speech server: see `SpeechBackend`).
/// Each turn is synthesized to a 24 kHz WAV and played sequentially with AVAudioPlayer.
///
/// Real audio gives us accurate per-turn durations (no char-based estimates).
/// The fluent interface mirrors the old AVSpeechSynthesizer player, so the UI
/// (DetailView / PlayerBar) is unchanged.
@MainActor
final class PlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var activeTurn: Int = -1
    @Published private(set) var turnCount = 0
    @Published var didEnd = false
    /// True until the first turn of a live render is ready to play. Later turns
    /// keep rendering in the background while the episode plays.
    @Published private(set) var isRendering = false
    /// Playback reached a turn that hasn't been rendered yet and is waiting for it.
    @Published private(set) var isBuffering = false
    /// Turns rendered so far in a live render (equals `turnCount` when complete).
    @Published private(set) var renderedCount = 0
    @Published private(set) var renderError: String?
    /// Turn playback is waiting on (see `isBuffering`).
    private var waitingForTurn: Int?
    /// Voice-sample preview, independent of the episode being listened to.
    enum PreviewPhase: Equatable {
        case generating(String)          // synthesizing the sample for this voice
        case playing(String)
        case failed(String, String)      // voice, message
        var voice: String {
            switch self { case .generating(let v), .playing(let v), .failed(let v, _): return v }
        }
    }
    @Published private(set) var preview: PreviewPhase?
    /// Fraction of the playing sample already heard (0…1), for the ring.
    @Published private(set) var previewProgress: Double = 0
    /// False until the Kokoro model has been loaded once; the first sample is slow.
    @Published private(set) var modelLoaded = false
    /// Speaking pace for synthesis (< 1 slower, > 1 faster), shared by voice
    /// samples, live rendering and import-time baking. `@Published` + defaults
    /// rather than `@AppStorage`, which doesn't notify views from an
    /// ObservableObject (the slider wouldn't redraw).
    nonisolated static let speedKey = "papertalk.voiceSpeed"
    nonisolated static let defaultSpeed = 0.95
    nonisolated static let speedRange = 0.5...2.0
    @Published var voiceSpeed: Double = PlayerController.storedSpeed() {
        didSet { UserDefaults.standard.set(voiceSpeed, forKey: Self.speedKey) }
    }
    private static func storedSpeed() -> Double {
        let v = UserDefaults.standard.double(forKey: speedKey)
        return speedRange.contains(v) ? v : defaultSpeed
    }
    private var previewPlayer: AVAudioPlayer?
    private var previewGeneration = 0
    private var previewTimer: Timer?

    private struct RenderedTurn {
        let wav: Data
        let duration: Double
    }

    private var turns: [String] = []           // speaker text per turn
    private var voices: [String] = []          // kokoro voice per turn
    private var rendered: [RenderedTurn?] = []
    private var player: AVAudioPlayer?
    private var generation = 0                 // invalidates in-flight renders on stop
    private var totalBefore: [Double] = []     // cumulative duration before each turn
    private var timer: Timer?

    // MARK: - Lifecycle

    /// Where samples and live renders are synthesized. `AppStore` keeps it
    /// in step with the speech settings.
    var speechBackend: any SpeechBackend

    init(speechBackend: any SpeechBackend) {
        self.speechBackend = speechBackend
        super.init()
    }

    func stopAll() {
        generation += 1
        timer?.invalidate(); timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        activeTurn = -1
        turnCount = 0
        turns = []
        voices = []
        rendered = []
        totalBefore = []
        didEnd = false
        renderError = nil
        isRendering = false
        isBuffering = false
        renderedCount = 0
        waitingForTurn = nil
    }

    /// Synthesize and play a short spoken sample of `voice` so the user can hear
    /// it before committing. Uses its own audio player: the episode is only
    /// paused, never unloaded. A new request replaces any running preview.
    func previewVoice(_ voice: String) {
        stopPreview()
        if isPlaying { pause() }
        previewGeneration += 1
        let gen = previewGeneration
        preview = .generating(voice)
        let backend = speechBackend
        Task { [self] in
            do {
                try await backend.prepare()
                modelLoaded = true
                let data = try await backend.synthesize(text: KokoroSpeech.samplePrompt(for: voice), voice: voice, speed: Float(voiceSpeed))
                guard gen == previewGeneration else { return }
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                previewPlayer = p
                previewProgress = 0
                p.play()
                preview = .playing(voice)
                startPreviewTimer()
            } catch {
                guard gen == previewGeneration else { return }
                preview = .failed(voice, error.localizedDescription)
            }
        }
    }

    /// Tracks the sample's progress. Kept out of the async preview task:
    /// corelibs Foundation (Linux) doesn't allow scheduling timers there.
    private func startPreviewTimer() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pp = self.previewPlayer, pp.duration > 0 else { return }
                self.previewProgress = min(1, pp.currentTime / pp.duration)
            }
        }
    }

    /// Cancel a generating sample or stop one that's playing.
    func stopPreview() {
        previewGeneration += 1
        previewTimer?.invalidate(); previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewProgress = 0
        preview = nil
    }

    /// Renders the transcript turn by turn. Playable as soon as the first turn
    /// is ready (`isRendering` clears); the rest render in the background and
    /// playback waits (`isBuffering`) if it catches up with the renderer.
    func prepare(transcript: Transcript, voiceMap: [String: String]) {
        let flat = transcript.segments.flatMap { $0.turns.map { (speaker: $0.speaker, text: $0.text) } }
        stopAll()
        guard !flat.isEmpty else { return }

        turnCount = flat.count
        turns = flat.map { $0.text }
        voices = flat.map { voiceMap[$0.speaker] ?? KokoroSpeech.defaultVoice }
        rendered = Array(repeating: nil, count: flat.count)
        totalBefore = []

        let gen = generation
        let backend = speechBackend
        isRendering = true
        renderError = nil
        Task {
            var running = 0.0
            for (i, text) in turns.enumerated() {
                if generation != gen { return }
                do {
                    // Short calls keep memory flat on long turns (see `KokoroSpeech.pieces`).
                    var parts: [Data] = []
                    for piece in backend.pieces(of: text) {
                        if generation != gen { return }
                        parts.append(try await backend.synthesize(text: piece, voice: voices[i], speed: Float(voiceSpeed)))
                    }
                    let wav = KokoroSpeech.joinWAVs(parts)
                    if generation != gen { return }
                    let d = KokoroSpeech.wavDuration(wav)
                    rendered[i] = RenderedTurn(wav: wav, duration: d)
                    totalBefore.append(running)
                    running += d + 0.35
                    duration = max(0, running - 0.35)   // grows as turns arrive
                    renderedCount = i + 1
                    isRendering = false
                    if waitingForTurn == i {
                        waitingForTurn = nil
                        isBuffering = false
                        startTurn(i)
                        player?.play()
                    }
                } catch {
                    if generation != gen { return }
                    renderError = "Couldn't voice section \(i + 1) of \(turns.count): \(error.localizedDescription)"
                    isRendering = false
                    if isBuffering { isBuffering = false; isPlaying = false; stopTimer() }
                    return
                }
            }
        }
    }

    /// Loads a pre-baked episode (one WAV per turn, as saved during import).
    /// No model work — the audio is already on disk.
    func prepare(baked: [BakedTurn]) {
        stopAll()
        guard !baked.isEmpty else { return }
        turnCount = baked.count
        voices = []
        turns = []
        rendered = baked.map { RenderedTurn(wav: $0.wav, duration: $0.duration) }
        renderedCount = baked.count
        var spans: [Double] = []
        var running = 0.0
        for r in rendered {
            spans.append(running)
            running += (r?.duration ?? 0) + 0.35
        }
        totalBefore = spans
        duration = max(0, running - 0.35)
    }

    // MARK: - Transport

    func playPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Plays now, or once the in-flight live render finishes (baked audio is
    /// already ready, so this returns immediately). Awaits without blocking.
    func playWhenReady() async {
        while isRendering && renderError == nil { try? await Task.sleep(nanoseconds: 30_000_000) }
        guard renderError == nil else { return }
        play()
    }

    private func play() {
        guard !isRendering else { return }
        let turn = activeTurn >= 0 ? activeTurn : 0
        if player == nil {
            if turn < rendered.count, rendered[turn] == nil, renderError == nil {
                // Resumed on a turn the live renderer hasn't reached yet.
                activeTurn = turn
                waitingForTurn = turn
                isBuffering = true
            } else {
                startTurn(turn)
            }
        }
        player?.play()
        isPlaying = true
        startTimer()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        isBuffering = false
        waitingForTurn = nil
        stopTimer()
    }

    /// Jump to an absolute time (0...duration) within the whole recording.
    func seek(toTime t: Double) {
        guard turnCount > 0, !isRendering else { return }
        var idx = 0
        for i in 0..<totalBefore.count where totalBefore[i] <= t { idx = i }
        let offset = max(0, min(t - totalBefore[idx], rendered[idx]?.duration ?? 0))
        player?.stop(); player = nil
        startTurn(idx)
        player?.currentTime = offset
        currentTime = totalBefore[idx] + offset
        if isPlaying { player?.play(); startTimer() }
    }

    /// Jump to the turn `delta` away from the current one (whole-turn skip).
    func skip(by delta: Int) {
        guard turnCount > 0, !isRendering else { return }
        let current = activeTurn >= 0 ? activeTurn : 0
        // Only turns that have been rendered can be jumped to.
        let target = min(max(current + delta, 0), max(0, renderedCount - 1))
        player?.stop(); player = nil
        startTurn(target)
        currentTime = target < totalBefore.count ? totalBefore[target] : 0
        if isPlaying { player?.play(); startTimer() }
    }

    private func startTurn(_ index: Int) {
        guard index >= 0, index < rendered.count, let r = rendered[index] else { return }
        activeTurn = index
        do {
            let p = try AVAudioPlayer(data: r.wav)
            p.delegate = self
            p.prepareToPlay()
            player = p
        } catch {
            renderError = error.localizedDescription
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ audioPlayer: AVAudioPlayer, successfully flag: Bool) {
        if audioPlayer === previewPlayer { stopPreview(); return }
        guard player === audioPlayer else { return }
        let next = activeTurn + 1
        if next < turnCount {
            if next < rendered.count, rendered[next] != nil {
                startTurn(next)
                player?.play()
            } else if renderError == nil {
                // Caught up with the live renderer: wait for the next turn.
                player = nil
                activeTurn = next
                waitingForTurn = next
                isBuffering = true
            } else {
                player = nil
                isPlaying = false
                stopTimer()
            }
        } else {
            player = nil
            isPlaying = false
            stopTimer()
            currentTime = duration
            didEnd = true
        }
    }

    // MARK: - Progress timing

    private func startTimer() {
        stopTimer()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this fires on the main actor.
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        t.tolerance = 0.05
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard activeTurn >= 0, activeTurn < totalBefore.count else { return }
        let p = player?.currentTime ?? 0
        currentTime = totalBefore[activeTurn] + min(p, rendered[activeTurn]?.duration ?? 0)
        if !isPlaying { stopTimer() }
    }
}