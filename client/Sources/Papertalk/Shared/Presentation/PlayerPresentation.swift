import Foundation

/// What the episode player is doing, for the status line under it. Derived
/// from the player's state so every view words it the same way.
enum PlaybackStatus: Equatable {
    case idle
    case preparingFirstSection
    case preparingNextSection
    case failed(String)

    /// The status for a paper's episode card: idle unless it's the loaded paper.
    static func forPaper(isLoaded: Bool, isRendering: Bool, isBuffering: Bool, error: String?) -> PlaybackStatus {
        isLoaded ? PlaybackStatus(isRendering: isRendering, isBuffering: isBuffering, error: error) : .idle
    }

    init(isRendering: Bool, isBuffering: Bool, error: String?) {
        if isRendering { self = .preparingFirstSection }
        else if isBuffering { self = .preparingNextSection }
        else if let error { self = .failed(error) }
        else { self = .idle }
    }

    var message: String? {
        switch self {
        case .idle: return nil
        case .preparingFirstSection: return L("Preparing the first section…")
        case .preparingNextSection: return L("Preparing the next section…")
        case .failed(let e): return e
        }
    }
}

/// The episode player bar's labels and which controls are usable.
enum PlayerBarPresentation {
    /// What sits under the title: a progress note, a fatal error, or the scrubber.
    enum Line: Equatable { case preparing(String), failed(String), scrubber }

    /// An error only replaces the scrubber when nothing was voiced at all;
    /// otherwise what's ready stays playable.
    static func line(isRendering: Bool, error: String?, renderedCount: Int) -> Line {
        if isRendering { return .preparing(PlaybackStatus.preparingFirstSection.message ?? "") }
        if let error, renderedCount == 0 { return .failed(error) }
        return .scrubber
    }

    /// "· 3 of 40", plus how far live voicing has got ("· voiced 12") while a
    /// fallback render is still running, or the buffering note.
    static func turnLabel(activeTurn: Int, turnCount: Int, renderedCount: Int,
                          isBuffering: Bool, hasError: Bool) -> String {
        guard turnCount > 0 else { return "" }
        if isBuffering { return "· " + L("preparing the next section…") }
        let base = "· " + L("{0} of {1}", max(activeTurn + 1, 1), turnCount)
        if renderedCount < turnCount, !hasError { return base + " · " + L("voiced {0}", renderedCount) }
        return base
    }

    static func playButton(isPlaying: Bool) -> (icon: String, help: String) {
        isPlaying ? ("pause.fill", L("Pause")) : ("play.fill", L("Play"))
    }

    static func canSkipBack(activeTurn: Int) -> Bool { max(activeTurn, 0) > 0 }
    static func canSkipForward(activeTurn: Int, turnCount: Int) -> Bool { activeTurn + 1 < turnCount }
    static func canPlay(isRendering: Bool, turnCount: Int) -> Bool { !isRendering && turnCount > 0 }

    static func timeLabel(_ time: Double, of duration: Double) -> String {
        "\(formatT(time)) / \(formatT(duration))"
    }
}

/// What the floating bar at the bottom of the library shows.
enum BottomBarContent: Equatable {
    /// A conversion is running and a different paper is loaded in the player.
    case playerAndImport(playing: Paper, importing: Paper)
    case importOnly(Paper)
    case player(Paper)
    case hidden

    /// The loaded paper earns its pane beside a running import; a paper that's
    /// merely selected doesn't push the import aside. Drawing a mind map leaves
    /// playback alone, so even the paper being mapped keeps its player.
    init(activeImport: Paper?, playing: Paper?, selected: Paper?) {
        if let run = activeImport {
            if let playing, playing.id != run.id || run.stage == Paper.mindMapStage {
                self = .playerAndImport(playing: playing, importing: run)
            }
            else { self = .importOnly(run) }
        } else if let paper = playing ?? selected {
            self = .player(paper)
        } else {
            self = .hidden
        }
    }
}

/// The player pane for one paper.
enum PlayerPane: Equatable {
    /// Audio is loaded (or loading) in the player: show the transport.
    case loaded
    /// Playable but not loaded yet: a Play/Resume button and a short label.
    case ready(playTitle: String, detail: String)
    /// Nothing to play, with the reason.
    case unavailable(String)

    init(paper: Paper, playerHasAudio: Bool) {
        if playerHasAudio { self = .loaded; return }
        if !paper.isActive && PaperPresentation.isPlayable(paper) {
            let detail: String
            if paper.progress > 1, paper.duration > 0 {
                detail = L("Resume at {0} of {1}", formatT(paper.progress), formatT(paper.duration))
            } else {
                detail = paper.duration > 0 ? L("{0} episode", formatT(paper.duration)) : L("Ready to play")
            }
            self = .ready(playTitle: paper.progress > 1 ? L("Resume") : L("Play"), detail: detail)
        } else {
            self = .unavailable(paper.isActive ? L("Episode is being produced…") : L("No episode for this paper yet"))
        }
    }
}

/// The import progress pane in the bottom bar.
enum ImportProgressPresentation {
    /// A mind map is one LLM call with no progress to report: the bar creeps
    /// towards `creepCeiling` while it waits, and completes when the map arrives.
    static let creepCeiling = 0.92
    static func creep(_ progress: Double) -> Double {
        progress >= creepCeiling ? progress : progress + (creepCeiling - progress) * 0.03
    }

    /// "2/3" when several imports run at once, else nil.
    static func counter(index: Int, count: Int) -> String? {
        count > 1 ? "\((index % count) + 1)/\(count)" : nil
    }

    static func stage(_ p: Paper) -> String { stageLabel(p.stage ?? "extract") }
}
