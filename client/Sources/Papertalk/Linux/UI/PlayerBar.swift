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

/// Transport for one paper, or how to start it: laid out like the macOS player bar, with the
/// transport on the left, then the cover, the title, where it is ("3 of 40") and the time, and
/// the scrubber under them.
struct PlayPane: View {
    var bridge: StoreBridge
    var paper: Paper

    var body: some View {
        let store = bridge.store
        let player = store.player
        HStack(alignment: .center, spacing: 14) {
            switch PlayerPane(paper: paper, playerHasAudio: player.hasAudio) {
            case .loaded:
                Transport(player: player)
            case .ready(let playTitle, _):
                Button(playTitle) { store.togglePlayback(paper.id) }
            case .unavailable:
                EmptyView()
            }
            CoverView(bridge: bridge, paperId: paper.id, width: 34, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(paper.displayTitle).font(.headline).lineLimit(1)
                    Text(turnLabel(player)).font(.caption).foregroundColor(.gray).lineLimit(1)
                    Spacer()
                    Text(PlayerBarPresentation.timeLabel(player.currentTime, of: player.duration))
                        .font(.caption).foregroundColor(.gray)
                }
                switch PlayerPane(paper: paper, playerHasAudio: player.hasAudio) {
                case .loaded:
                    switch PlayerBarPresentation.line(isRendering: player.isRendering, error: player.renderError,
                                                      renderedCount: player.renderedCount) {
                    case .preparing(let label):
                        Text(label).font(.caption).foregroundColor(.gray)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundColor(.red)
                    case .scrubber:
                        Slider(value: Binding(get: { player.currentTime }, set: { bridge.scrub(to: $0) }),
                               in: 0...max(player.duration, 1))
                    }
                case .ready(_, let detail):
                    Text(detail).font(.caption).foregroundColor(.gray)
                case .unavailable(let reason):
                    Text(reason).font(.caption).foregroundColor(.gray)
                }
            }
        }
    }

    /// "· 3 of 40", as on macOS.
    private func turnLabel(_ player: PlayerController) -> String {
        PlayerBarPresentation.turnLabel(activeTurn: player.activeTurn, turnCount: player.turnCount,
                                        renderedCount: player.renderedCount,
                                        isBuffering: player.isBuffering, hasError: player.renderError != nil)
    }
}

/// Previous turn, play/pause and next turn, as icon buttons.
struct Transport: View {
    var player: PlayerController

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { player.skip(by: -1) }) { Text(PlayerGlyph.previous).font(.system(size: 13)).frame(width: 34) }
                .disabled(!PlayerBarPresentation.canSkipBack(activeTurn: player.activeTurn))
            Button(action: { player.playPause() }) {
                Text(PlayerGlyph.playPause(isPlaying: player.isPlaying)).font(.system(size: 20))
                    .frame(width: 40, height: 30)
            }
            .disabled(!PlayerBarPresentation.canPlay(isRendering: player.isRendering, turnCount: player.turnCount))
            Button(action: { player.skip(by: 1) }) { Text(PlayerGlyph.next).font(.system(size: 13)).frame(width: 34) }
                .disabled(!PlayerBarPresentation.canSkipForward(activeTurn: player.activeTurn, turnCount: player.turnCount))
        }
    }
}

/// The transport's symbols (macOS uses SF Symbols, which GTK doesn't have). Geometric shapes
/// every common desktop font has: the media-control block (⏮ ⏸ ⏭) is missing from DejaVu
/// and Cantarell and showed as empty boxes.
enum PlayerGlyph {
    /// Previous turn.
    static let previous = "◀◀"
    /// Next turn.
    static let next = "▶▶"
    /// Pause while playing, play otherwise.
    static func playPause(isPlaying: Bool) -> String { isPlaying ? "‖" : "▶" }
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
