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
                    Text("\(formatT(displayTime)) / \(formatT(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if player.isRendering {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Preparing voices…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(height: 14)
                } else {
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
        guard player.turnCount > 0 else { return "" }
        return "· \(max(activeTurn + 1, 1)) of \(player.turnCount)"
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                skipButton(-1, systemImage: "backward.fill", help: "Previous turn",
                           enabled: (player.activeTurn >= 0 ? player.activeTurn : 0) > 0)
                Button {
                    player.playPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.tint(Color.appAccent).interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(player.isRendering || player.turnCount == 0)
                .help(player.isPlaying ? "Pause" : "Play")
                skipButton(1, systemImage: "forward.fill", help: "Next turn",
                           enabled: player.activeTurn + 1 < player.turnCount)
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

    /// The paper the player currently holds (falls back to the selection).
    private var paper: Paper? {
        store.playingPaperId.flatMap { store.papers[$0] } ?? store.selectedPaper()
    }

    var body: some View {
        Group {
            if let run = store.activeRun {
                capsule { importProgress(run) }
            } else if let paper {
                capsule {
                    if player.turnCount > 0 || player.isRendering {
                        PlayerBar(player: player,
                                  onSeek: { player.seek(toTime: $0) },
                                  activeTurn: player.activeTurn,
                                  paper: paper)
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.slash")
                                .foregroundStyle(.secondary)
                            Text(paper.isActive ? "Episode is being produced…" : "No audio for this paper yet")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(height: 28)
                    }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: store.activeRun?.id)
        .animation(.spring(duration: 0.35), value: paper?.id)
    }

    private func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 760)
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
                    Text(stageLabel(p.stage ?? "extract"))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("· " + p.displayTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if p.isError {
                        Button("Dismiss") { store.resetError(p.id) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    } else {
                        Text("\(Int((max(0.02, p.progress) * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: min(1, max(0.02, p.progress)))
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
}

// MARK: - Highlight active word within a cue by current time
struct WordHighlighter: View {
    let tokens: [String]
    var body: some View { Text(joined) }
    private var joined: AttributedString {
        // Without live word timing, show plain text (words already space-joined).
        AttributedString(tokens.joined(separator: " "))
    }
}
