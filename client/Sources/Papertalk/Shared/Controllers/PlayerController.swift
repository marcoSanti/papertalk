// Episode playback and voice samples (`PlayerController`), shared by every player control and
// by the system's Now Playing.

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

/// The one episode player. It plays an episode as a sequence of per-turn WAVs (one
/// AVAudioPlayer at a time, a short pause between turns): baked audio loaded from disk
/// (`prepare(baked:)`), or, for a paper without saved audio, turns voiced live as it plays
/// (`prepare(transcript:voiceMap:)`). It also plays the cast sheet's voice samples.
@MainActor
final class PlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// Audio is playing (false while paused, stopped or buffering a live turn).
    @Published var isPlaying = false
    /// Seconds into the whole episode, pauses between turns included.
    @Published var currentTime: Double = 0
    /// The episode's length in seconds; grows while a live render runs.
    @Published var duration: Double = 0
    /// The turn playing, -1 before the first.
    @Published private(set) var activeTurn: Int = -1
    /// Turns in the loaded episode; 0 when nothing is loaded.
    @Published private(set) var turnCount = 0
    /// Set when the last turn finishes (the store saves progress and offers to delete the audio).
    @Published var didEnd = false
    /// True until the first turn of a live render is ready to play. Later turns
    /// keep rendering in the background while the episode plays.
    @Published private(set) var isRendering = false
    /// Playback reached a turn that hasn't been rendered yet and is waiting for it.
    @Published private(set) var isBuffering = false
    /// Turns rendered so far in a live render (equals `turnCount` when complete).
    @Published private(set) var renderedCount = 0
    /// Why live voicing stopped, if it did; what's voiced stays playable.
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
    /// The voice sample in progress, if any.
    @Published private(set) var preview: PreviewPhase?
    /// Fraction of the playing sample already heard (0…1), for the ring.
    @Published private(set) var previewProgress: Double = 0
    /// False until the Kokoro model has been loaded once; the first sample is slow.
    @Published private(set) var modelLoaded = false
    /// The next sample has to load the model first (never on a speech server).
    var sampleLoadsModel: Bool { speechBackend.loadsModel && !modelLoaded }
    /// Speaking pace for synthesis (< 1 slower, > 1 faster), shared by voice
    /// samples, live rendering and import-time baking. `@Published` + defaults
    /// rather than `@AppStorage`, which doesn't notify views from an
    /// ObservableObject (the slider wouldn't redraw).
    nonisolated static let speedKey = "papertalk.voiceSpeed"
    /// Slightly under 1: Kokoro reads clearer a little slower.
    nonisolated static let defaultSpeed = 0.95
    /// What the pace slider allows.
    nonisolated static let speedRange = 0.5...2.0
    /// The chosen pace, saved for the next launch.
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

    /// A voiced turn ready to play.
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

    /// A player that voices samples and live renders with `speechBackend`.
    init(speechBackend: any SpeechBackend) {
        self.speechBackend = speechBackend
        super.init()
    }

    /// Stop and unload the episode; an in-flight live render is abandoned.
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

    /// Turns a live render voices ahead of the playing one.
    nonisolated static let liveAhead = 3
    /// Turns a live render keeps behind the playing one (for a quick skip back).
    nonisolated static let liveBehind = 1

    /// Voices the transcript as it plays, through a window around the playing turn: up to
    /// `liveAhead` turns ahead are voiced, turns outside the window are dropped from memory, and
    /// nothing is written to disk. Playable as soon as the first turn is ready (`isRendering`
    /// clears); playback waits (`isBuffering`) on a turn not voiced yet, including one dropped
    /// earlier and voiced again after a seek back.
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
        Task { [weak self] in
            var running = 0.0
            while let self, self.generation == gen {
                guard let i = self.nextTurnToVoice() else {
                    // The window is full: wait for playback to move it.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                do {
                    // Short calls keep memory flat on long turns (see `KokoroSpeech.pieces`).
                    var parts: [Data] = []
                    for piece in backend.pieces(of: self.turns[i]) {
                        if self.generation != gen { return }
                        parts.append(try await backend.synthesize(text: piece, voice: self.voices[i], speed: Float(self.voiceSpeed)))
                    }
                    let wav = KokoroSpeech.joinWAVs(parts)
                    if self.generation != gen { return }
                    let d = KokoroSpeech.wavDuration(wav)
                    self.rendered[i] = RenderedTurn(wav: wav, duration: d)
                    if i == self.renderedCount {
                        // First time this turn is voiced: extend the timeline.
                        self.totalBefore.append(running)
                        running += d + 0.35
                        self.duration = max(0, running - 0.35)   // grows as turns arrive
                        self.renderedCount = i + 1
                    }
                    self.isRendering = false
                    if self.waitingForTurn == i {
                        self.waitingForTurn = nil
                        self.isBuffering = false
                        self.startTurn(i)
                        self.player?.play()
                    }
                } catch {
                    if self.generation != gen { return }
                    self.renderError = L("Couldn't voice section {0} of {1}: {2}", i + 1, self.turns.count, error.localizedDescription)
                    self.isRendering = false
                    if self.isBuffering { self.isBuffering = false; self.isPlaying = false; self.stopTimer() }
                    return
                }
            }
        }
    }

    /// The live window around the playing turn (empty for baked audio).
    private var liveWindow: ClosedRange<Int> {
        let at = max(activeTurn, 0)
        return max(0, at - Self.liveBehind)...min(turnCount - 1, at + Self.liveAhead)
    }

    /// The first turn from the playing one to the window's end that isn't voiced.
    private func nextTurnToVoice() -> Int? {
        (max(activeTurn, 0)...liveWindow.upperBound).first { rendered[$0] == nil }
    }

    /// Frees live turns that fell out of the window.
    private func dropTurnsOutsideWindow() {
        guard !turns.isEmpty else { return }
        let window = liveWindow
        for i in rendered.indices where !window.contains(i) { rendered[i] = nil }
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

    /// Toggle playback of the loaded episode.
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

    /// Start or resume; on a live turn not voiced yet, wait for it (`isBuffering`).
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

    /// Pause, keeping the position.
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
        jump(to: idx)
        player?.currentTime = offset
        currentTime = totalBefore[idx] + (player == nil ? 0 : offset)
    }

    /// Jump to the turn `delta` away from the current one (whole-turn skip).
    func skip(by delta: Int) {
        guard turnCount > 0, !isRendering else { return }
        let current = activeTurn >= 0 ? activeTurn : 0
        // Only turns that have been rendered can be jumped to.
        let target = min(max(current + delta, 0), max(0, renderedCount - 1))
        jump(to: target)
        currentTime = target < totalBefore.count ? totalBefore[target] : 0
    }

    /// Move to turn `index`, keeping play or pause. A live turn dropped from memory starts over
    /// from its beginning once it's voiced again.
    private func jump(to index: Int) {
        player?.stop(); player = nil
        startTurn(index)
        if player == nil {
            activeTurn = index
            dropTurnsOutsideWindow()
            if isPlaying { waitingForTurn = index; isBuffering = true }
        } else if isPlaying {
            player?.play(); startTimer()
        }
    }

    /// Load turn `index` into a fresh AVAudioPlayer (it doesn't start playing).
    private func startTurn(_ index: Int) {
        guard index >= 0, index < rendered.count, let r = rendered[index] else { return }
        activeTurn = index
        dropTurnsOutsideWindow()
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

    /// A turn (or a sample) finished: move to the next turn, wait for it, or end.
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

    /// Update `currentTime` five times a second while playing.
    private func startTimer() {
        stopTimer()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this fires on the main actor.
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        t.tolerance = 0.05
    }

    /// Stop updating `currentTime`.
    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// The episode position: the turns before this one plus the position in it.
    private func tick() {
        guard activeTurn >= 0, activeTurn < totalBefore.count else { return }
        let p = player?.currentTime ?? 0
        currentTime = totalBefore[activeTurn] + min(p, rendered[activeTurn]?.duration ?? 0)
        if !isPlaying { stopTimer() }
    }
}