#if os(macOS)
import SwiftUI

// MARK: - Player bar (transport + scrubber + now-playing info)
struct PlayerBar: View {
    @ObservedObject var player: PlayerController
    let onSeek: (Double) -> Void
    let activeTurn: Int
    let paper: Paper
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            transport
            PaperArtwork(paper: paper)
                .frame(width: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(paper.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(turnLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(PlayerBarPresentation.timeLabel(displayTime, of: player.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                switch PlayerBarPresentation.line(isRendering: player.isRendering, error: player.renderError,
                                                  renderedCount: player.renderedCount) {
                case .preparing(let note):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(height: 14)
                case .failed(let err):
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(err)
                        .frame(height: 14)
                case .scrubber:
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubValue : player.currentTime },
                            set: { scrubValue = $0 }),
                        in: 0...max(player.duration, 1),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if editing { scrubValue = player.currentTime }
                            if !editing { onSeek(scrubValue) }
                        }
                    )
                    .controlSize(.mini)
                    .disabled(player.duration <= 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var displayTime: Double { isScrubbing ? scrubValue : player.currentTime }

    private var turnLabel: String {
        PlayerBarPresentation.turnLabel(activeTurn: activeTurn, turnCount: player.turnCount,
                                        renderedCount: player.renderedCount,
                                        isBuffering: player.isBuffering, hasError: player.renderError != nil)
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                skipButton(-1, systemImage: "backward.fill", help: "Previous turn",
                           enabled: PlayerBarPresentation.canSkipBack(activeTurn: player.activeTurn))
                Button {
                    player.playPause()
                } label: {
                    Image(systemName: PlayerBarPresentation.playButton(isPlaying: player.isPlaying).icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.tint(Color.appAccent).interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!PlayerBarPresentation.canPlay(isRendering: player.isRendering, turnCount: player.turnCount))
                .help(PlayerBarPresentation.playButton(isPlaying: player.isPlaying).help)
                skipButton(1, systemImage: "forward.fill", help: "Next turn",
                           enabled: PlayerBarPresentation.canSkipForward(activeTurn: player.activeTurn,
                                                                         turnCount: player.turnCount))
            }
        }
    }

    private func skipButton(_ delta: Int, systemImage: String, help: String, enabled: Bool) -> some View {
        Button {
            player.skip(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}

// MARK: - Floating glass "now playing" / import status capsule
struct BottomBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PlayerController

    var body: some View {
        let content = BottomBarContent(activeImport: store.shownProgress,
                                       playing: store.playingPaperId.flatMap { store.papers[$0] },
                                       selected: store.selectedPaper())
        Group {
            switch content {
            case .playerAndImport(let playing, let run):
                capsule(maxWidth: 1100) {
                    HStack(spacing: 16) {
                        playPane(playing)
                        Divider().frame(height: 40)
                        importPane(run)
                    }
                }
            case .importOnly(let run):
                capsule { importProgress(run) }
            case .player(let paper):
                capsule { playPane(paper) }
            case .hidden:
                EmptyView()
            }
        }
        .animation(.spring(duration: 0.35), value: content)
    }

    @ViewBuilder
    private func playPane(_ paper: Paper) -> some View {
        pane {
            switch PlayerPane(paper: paper, playerHasAudio: player.turnCount > 0 || player.isRendering) {
            case .loaded:
                PlayerBar(player: player,
                          onSeek: { player.seek(toTime: $0) },
                          activeTurn: player.activeTurn,
                          paper: paper)
            case .ready(let playTitle, let detail):
                HStack(spacing: 12) {
                    Button {
                        store.togglePlayback(paper.id)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular.tint(Color.appAccent).interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(playTitle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paper.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            case .unavailable(let reason):
                HStack(spacing: 10) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 28)
            }
        }
    }

    private func importPane(_ run: Paper) -> some View {
        pane {
            importProgress(run)
        }
    }

    private func pane<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capsule<C: View>(maxWidth: CGFloat = 760,
                                  @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: maxWidth)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func importProgress(_ p: Paper) -> some View {
        HStack(spacing: 12) {
            if let counter = ImportProgressPresentation.counter(index: store.activeRunIndex, count: store.progressItems.count) {
                VStack(spacing: 8) {
                    arrowButton("chevron.up", -1)
                    arrowButton("chevron.down", 1)
                    Text(counter)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }
            ZStack {
                if p.isError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 36, height: 36)
            .glassEffect(.regular.tint(p.isError ? Color.red.opacity(0.25) : Color.appAccent.opacity(0.25)), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(ImportProgressPresentation.stage(p))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("· " + p.displayTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if p.isError {
                        Button(L("Dismiss")) { store.resetError(p.id) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    } else {
                        Text(ConversionPresentation.percentLabel(p.progress))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: ConversionPresentation.barValue(p.progress))
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                    .animation(.easeInOut(duration: 0.25), value: p.progress)
                if let m = p.message, !m.isEmpty {
                    Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func arrowButton(_ systemImage: String, _ delta: Int) -> some View {
        Button {
            store.focusImport(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(delta < 0 ? L("Previous import") : L("Next import"))
    }
}

#endif
