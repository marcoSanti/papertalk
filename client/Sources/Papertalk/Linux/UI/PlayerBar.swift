// The Linux player bar under the details pane: playback, scrubber and import progress.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// The bottom bar: the loaded episode's transport and the running import,
/// chosen by the same BottomBarContent rules as on macOS.
struct PlayerBar: View {
    @State var bridge: StoreBridge

    var body: some View {
        let store = bridge.store
        let content = BottomBarContent(activeImport: store.shownProgress,
                                       playing: store.playingPaper,
                                       selected: store.selectedPaper())
        VStack(alignment: .leading, spacing: 8) {
            if let toast = store.toast {
                Text(toast).foregroundColor(.blue)
            }
            switch content {
            case .playerAndImport(let playing, let run):
                PlayPane(bridge: bridge, paper: playing)
                ImportPane(bridge: bridge, paper: run)
            case .importOnly(let run):
                ImportPane(bridge: bridge, paper: run)
            case .player(let paper):
                PlayPane(bridge: bridge, paper: paper)
            case .hidden:
                EmptyView()
            }
        }
        .padding(16)
        .onAppear { bridge.windowAppeared() }
    }
}

/// Transport for one paper, or how to start it.
struct PlayPane: View {
    var bridge: StoreBridge
    var paper: Paper

    var body: some View {
        let store = bridge.store
        let player = store.player
        VStack(alignment: .leading, spacing: 6) {
            Text(paper.displayTitle).font(.headline).lineLimit(1)
            switch PlayerPane(paper: paper, playerHasAudio: player.hasAudio) {
            case .loaded:
                switch PlayerBarPresentation.line(isRendering: player.isRendering, error: player.renderError,
                                                  renderedCount: player.renderedCount) {
                case .preparing(let label):
                    Text(label).foregroundColor(.gray)
                case .failed(let message):
                    Text(message).foregroundColor(.red)
                case .scrubber:
                    HStack(spacing: 8) {
                        Button(L("Back")) { player.skip(by: -1) }
                            .disabled(!PlayerBarPresentation.canSkipBack(activeTurn: player.activeTurn))
                        Button(PlayerBarPresentation.playButton(isPlaying: player.isPlaying).help) { player.playPause() }
                            .disabled(!PlayerBarPresentation.canPlay(isRendering: player.isRendering, turnCount: player.turnCount))
                        Button(L("Next")) { player.skip(by: 1) }
                            .disabled(!PlayerBarPresentation.canSkipForward(activeTurn: player.activeTurn, turnCount: player.turnCount))
                        Slider(value: Binding(get: { player.currentTime }, set: { player.seek(toTime: $0) }),
                               in: 0...max(player.duration, 1))
                        Text(PlayerBarPresentation.timeLabel(player.currentTime, of: player.duration)).font(.caption)
                    }
                }
            case .ready(let playTitle, let detail):
                HStack(spacing: 8) {
                    Button(playTitle) { store.togglePlayback(paper.id) }
                    Text(detail).foregroundColor(.gray)
                }
            case .unavailable(let reason):
                Text(reason).foregroundColor(.gray)
            }
        }
    }
}

/// The running import's stage and progress.
struct ImportPane: View {
    var bridge: StoreBridge
    var paper: Paper

    var body: some View {
        let store = bridge.store
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Importing “{0}”", paper.displayTitle)).lineLimit(1)
                Spacer()
                Text(ImportProgressPresentation.counter(index: store.activeRunIndex, count: store.progressItems.count) ?? "")
                    .foregroundColor(.gray)
            }
            HStack {
                Text(ImportProgressPresentation.detailLine(paper)).font(.caption).foregroundColor(.gray)
                Spacer()
                Text(ConversionPresentation.percentLabel(paper.progress)).font(.caption)
            }
            ProgressView("", value: ConversionPresentation.barValue(paper.progress))
        }
    }
}
#endif
