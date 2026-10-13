import Foundation
import AVFoundation
import Combine
import FluidAudio

/// Speaks a paper's transcript using Kokoro neural voices (on-device Core ML /
/// Neural Engine via FluidAudio). Each turn is synthesized to a 24 kHz WAV and
/// played sequentially with AVAudioPlayer.
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
    /// True while the transcript's turns are being rendered to audio.
    @Published private(set) var isRendering = false
    @Published private(set) var renderError: String?

    private struct RenderedTurn {
        let wav: Data
        let duration: Double
    }

    private let manager = KokoroAneManager(variant: .english)
    private var turns: [String] = []           // speaker text per turn
    private var voices: [String] = []          // kokoro voice per turn
    private var rendered: [RenderedTurn?] = []
    private var player: AVAudioPlayer?
    private var generation = 0                 // invalidates in-flight renders on stop
    private var totalBefore: [Double] = []     // cumulative duration before each turn
    private var timer: Timer?

    // MARK: - Lifecycle

    override init() {
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
    }

    /// Renders every turn to audio (async). Not ready until `isRendering` clears.
    func prepare(transcript: Transcript) {
        let flat = transcript.segments.flatMap { $0.turns.map { (speaker: $0.speaker, text: $0.text) } }
        stopAll()
        guard !flat.isEmpty else { return }

        turnCount = flat.count
        turns = flat.map { $0.text }
        let voiceMap = KokoroSpeech.voices(for: flat.map { $0.speaker })
        voices = flat.map { voiceMap[$0.speaker] ?? KokoroSpeech.defaultVoice }
        rendered = Array(repeating: nil, count: flat.count)
        totalBefore = [] // filled after each render

        let gen = generation
        isRendering = true
        renderError = nil
        Task {
            do {
                try await manager.initialize()
                var nextDurations: [Double] = []
                for (i, text) in turns.enumerated() {
                    if generation != gen { return }
                    let wav = try await manager.synthesize(text: text, voice: voices[i], speed: 0.95)
                    if generation != gen { return }
                    nextDurations.append(nextDurations.last.map { $0 + 0.35 } ?? 0.35) // before+tiny gap
                    rendered[i] = RenderedTurn(wav: wav, duration: KokoroSpeech.wavDuration(wav))
                }
                if generation != gen { return }
                totalBefore = nextDurations
                duration = totalBefore.last.map { $0 + (rendered.last??.duration ?? 0) } ?? 0
                isRendering = false
            } catch {
                if generation != gen { return }
                renderError = error.localizedDescription
                isRendering = false
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
        totalBefore = baked.indices.map { Double($0 + 1) * 0.35 } // cumulative fixed gap, matches live path
        duration = totalBefore.last.map { $0 + (rendered.last??.duration ?? 0) } ?? 0
    }

    // MARK: - Transport

    func playPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    private func play() {
        guard !isRendering else { return }
        if player == nil { startTurn(activeTurn >= 0 ? activeTurn : 0) }
        player?.play()
        isPlaying = true
        startTimer()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to fraction: Double) {
        guard turnCount > 0, !isRendering else { return }
        let index = min(max(Int(fraction * Double(turnCount)), 0), turnCount - 1)
        player?.stop(); player = nil
        startTurn(index)
        currentTime = index < totalBefore.count ? totalBefore[index] : 0
        if isPlaying { player?.play(); startTimer() }
    }

    /// Jump to the turn `delta` away from the current one (whole-turn skip).
    func skip(by delta: Int) {
        guard turnCount > 0, !isRendering else { return }
        let current = activeTurn >= 0 ? activeTurn : 0
        let target = min(max(current + delta, 0), turnCount - 1)
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
        guard player === audioPlayer else { return }
        let next = activeTurn + 1
        if next < turnCount {
            startTurn(next)
            player?.play()
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
            self?.tick()
        }
        timer = t
        t.tolerance = 0.05
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard activeTurn >= 0, activeTurn < totalBefore.count else { return }
        let p = player?.currentTime ?? 0
        let before = totalBefore[activeTurn]
        let durBefore = rendered[activeTurn]?.duration ?? 0
        currentTime = before + min(p, durBefore)
        if !isPlaying { stopTimer() }
    }
}