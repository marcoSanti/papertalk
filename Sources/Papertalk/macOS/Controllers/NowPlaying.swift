// The bridge to the system's Now Playing (Control Center, media keys) on macOS.

#if os(macOS)
import AppKit
import Combine
import MediaPlayer

/// Shows the loaded episode in Control Center's Now Playing and answers the
/// media keys and its buttons. Commands go through the same store and player
/// methods as the player bar; what is shown comes from `NowPlayingPresentation`.
@MainActor
final class NowPlaying {
    /// There is one system Now Playing, so one bridge.
    static let shared = NowPlaying()

    private weak var store: AppStore?
    private var cancellables: Set<AnyCancellable> = []
    private var published: NowPlayingInfo?
    private var publishedAt = Date()
    private var refreshQueued = false
    private var artwork: (id: String, art: MPMediaItemArtwork?)?

    /// Wire once at launch. Safe to call again (the second call is ignored).
    func attach(to store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        registerCommands()
        // objectWillChange fires before the value lands: read it a turn later.
        store.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &cancellables)
        store.player.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &cancellables)
        queueRefresh()
    }

    /// Coalesce the store's and player's changes into one refresh on the next run loop turn.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.refreshQueued = false
                self.refresh()
            }
        }
    }

    /// Work out what to show and publish it if it changed enough.
    private func refresh() {
        guard let store else { return }
        let player = store.player
        let info = NowPlayingPresentation.info(
            paper: store.playingPaperId.flatMap { store.papers[$0] }, turnCount: player.turnCount,
            isPlaying: player.isPlaying, isBuffering: player.isBuffering,
            currentTime: player.currentTime, duration: player.duration)
        guard NowPlayingPresentation.needsPublish(info, after: published,
                                                  secondsSince: Date().timeIntervalSince(publishedAt)) else { return }
        publish(info)
    }

    /// Hand the info (and cover) to the system, or clear it.
    private func publish(_ info: NowPlayingInfo?) {
        published = info
        publishedAt = Date()
        let center = MPNowPlayingInfoCenter.default()
        setCommandsEnabled(info != nil)
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.isAdvancing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = info.artist { dict[MPMediaItemPropertyArtist] = artist }
        if artwork?.id == info.paperId {
            if let art = artwork?.art { dict[MPMediaItemPropertyArtwork] = art }
        } else {
            loadArtwork(for: info.paperId)
        }
        center.nowPlayingInfo = dict
        center.playbackState = info.isAdvancing ? .playing : .paused
    }

    /// The cover loads asynchronously; once it's in, publish again with it.
    private func loadArtwork(for id: String) {
        artwork = (id, nil)
        Task {
            guard let image = await store?.loadThumbnail(id), artwork?.id == id else { return }
            let box = ImageBox(image: image)
            artwork = (id, MPMediaItemArtwork(boundsSize: image.size) { _ in box.image })
            published = nil
            refresh()
        }
    }

    // MARK: - Remote commands

    /// Answer play, pause, toggle, skip ±15 s and scrubbing from the system.
    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.forward { $0.playPause(.play) } ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in self?.forward { $0.playPause(.pause) } ?? .commandFailed }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.forward { $0.playPause(.toggle) } ?? .commandFailed }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.forward { $0.store?.player.skip(by: 1) } ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.forward { $0.store?.player.skip(by: -1) } ?? .commandFailed }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: NowPlayingPresentation.skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: NowPlayingPresentation.skipInterval)]
        c.skipForwardCommand.addTarget { [weak self] _ in
            self?.forward { $0.skip(NowPlayingPresentation.skipInterval) } ?? .commandFailed
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            self?.forward { $0.skip(-NowPlayingPresentation.skipInterval) } ?? .commandFailed
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return self?.forward { $0.store?.player.seek(toTime: time) } ?? .commandFailed
        }
        setCommandsEnabled(false)
    }

    private var commands: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand,
                c.previousTrackCommand, c.skipForwardCommand, c.skipBackwardCommand,
                c.changePlaybackPositionCommand]
    }

    /// Grey out the system's buttons when nothing is loaded.
    private func setCommandsEnabled(_ enabled: Bool) {
        for command in commands where command.isEnabled != enabled { command.isEnabled = enabled }
    }

    /// Handlers may arrive off the main thread; the work always runs on it.
    nonisolated private func forward(_ action: @escaping @MainActor (NowPlaying) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            action(self)
            self.queueRefresh()
        }
        return .success
    }

    /// Play, pause or toggle through the store, like the player bar.
    private func playPause(_ command: NowPlayingPresentation.Command) {
        guard let store, let id = store.playingPaperId,
              NowPlayingPresentation.shouldToggle(command, isPlaying: store.player.isPlaying) else { return }
        store.togglePlayback(id)
    }

    /// Jump within the episode.
    private func skip(_ seconds: Double) {
        guard let player = store?.player else { return }
        player.seek(toTime: NowPlayingPresentation.skipTarget(from: player.currentTime, by: seconds,
                                                              duration: player.duration))
    }
}

/// Lets the artwork handler, which the system may call on any thread, hand
/// back an image that is never mutated after loading.
/// Carries the cover into the artwork's sendable closure.
private final class ImageBox: @unchecked Sendable {
    let image: NSImage
    init(image: NSImage) { self.image = image }
}
#endif
