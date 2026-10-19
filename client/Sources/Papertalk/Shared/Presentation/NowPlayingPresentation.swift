import Foundation

/// What the system's Now Playing (Control Center, media keys) is told about the
/// loaded episode. Pure values; the macOS bridge only copies them across.
struct NowPlayingInfo: Equatable {
    var paperId: String
    var title: String
    var artist: String?
    var duration: Double
    var elapsed: Double
    /// Audio is actually advancing: playing and not waiting on a section.
    var isAdvancing: Bool
}

enum NowPlayingPresentation {
    /// Seconds jumped by the system's skip-forward / skip-back buttons.
    static let skipInterval: Double = 15

    /// Nil when nothing is loaded, which clears Now Playing.
    static func info(paper: Paper?, turnCount: Int, isPlaying: Bool, isBuffering: Bool,
                     currentTime: Double, duration: Double) -> NowPlayingInfo? {
        guard let paper, turnCount > 0 else { return nil }
        return NowPlayingInfo(paperId: paper.id,
                              title: paper.displayTitle,
                              artist: paper.authors.isEmpty ? nil : PaperPresentation.authorLine(paper.authors),
                              duration: max(0, duration),
                              elapsed: min(max(0, currentTime), max(0, duration)),
                              isAdvancing: isPlaying && !isBuffering)
    }

    /// The system extrapolates elapsed time from the playback rate, so the
    /// player's 5 Hz ticks needn't be sent. Publish when anything else changed,
    /// or when elapsed jumped (a seek or skip) away from where the system thinks it is.
    static func needsPublish(_ new: NowPlayingInfo?, after old: NowPlayingInfo?, secondsSince: Double) -> Bool {
        guard let new, let old else { return (new == nil) != (old == nil) }
        var unchanged = new
        unchanged.elapsed = old.elapsed
        if unchanged != old { return true }
        let expected = old.elapsed + (old.isAdvancing ? max(0, secondsSince) : 0)
        return abs(new.elapsed - expected) > 1
    }

    /// Where a skip of `delta` seconds lands, kept inside the episode.
    static func skipTarget(from time: Double, by delta: Double, duration: Double) -> Double {
        min(max(0, time + delta), max(0, duration))
    }

    /// The system's play / pause / toggle commands, as a toggle or nothing:
    /// "play" while already playing does nothing.
    enum Command { case play, pause, toggle }
    static func shouldToggle(_ command: Command, isPlaying: Bool) -> Bool {
        switch command {
        case .play: return !isPlaying
        case .pause: return isPlaying
        case .toggle: return true
        }
    }
}
