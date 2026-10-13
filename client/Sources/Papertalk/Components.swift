import SwiftUI

// MARK: - Flow tags (chip layout, removable)
struct FlowTags: View {
    let tags: [String]
    var onRemove: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunks, id: \.self) { row in
                HStack(spacing: 6) { ForEach(row, id: \.self) { chip($0) } }
            }
        }
    }
    private var chunks: [[String]] { stride(from: 0, to: tags.count, by: 3).map { Array(tags[$0..<min($0+3, tags.count)]) } }
    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)").font(.caption)
            Button { onRemove(tag) } label: { Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

// MARK: - Player bar (bottom status bar transport + paper info)
struct PlayerBar: View {
    @ObservedObject var player: PlayerController
    let onSeek: (Double) -> Void
    let activeTurn: Int
    let paper: Paper
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                skipButton(-1, systemImage: "backward.end.fill", help: "Previous turn", enabled: (player.activeTurn >= 0 ? player.activeTurn : 0) > 0)
                playButton
                skipButton(1, systemImage: "forward.end.fill", help: "Next turn", enabled: player.activeTurn + 1 < player.turnCount)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.isPlaying ? "Playing" : "Paused")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(turnLabel).font(.callout).lineLimit(1)
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.displayTitle).font(.callout.bold()).lineLimit(1)
                    Text(authorsList(paper)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 140, maxWidth: 360, alignment: .leading)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(formatT(displayTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0 }),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { onSeek(scrubValue) }
                    }
                )
                .disabled(player.duration <= 0)
                .frame(minWidth: 200, maxWidth: .infinity)
                Text(formatT(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayTime: Double { isScrubbing ? scrubValue : player.currentTime }

    private func authorsList(_ p: Paper) -> String {
        p.authors.isEmpty ? "Unknown authors" : p.authors.prefix(3).joined(separator: ", ") + (p.authors.count > 3 ? " et al." : "")
    }

    private var turnLabel: String {
        guard player.turnCount > 0 else { return "No audio yet" }
        return "Section \(max(activeTurn + 1, 1)) of \(player.turnCount)"
    }

    private var playButton: some View {
        Button {
            player.playPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(_ delta: Int, systemImage: String, help: String, enabled: Bool) -> some View {
        Button {
            player.skip(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

private func formatT(_ s: Double) -> String {
    guard s.isFinite else { return "–:––" }
    let m = Int(s) / 60, sec = Int(s) % 60
    return "\(m):" + String(format: "%02d", sec)
}

// MARK: - Bottom global status bar (iTunes-style): active import OR selected paper + player
struct BottomBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PlayerController

    var body: some View {
        HStack(spacing: 24) {
            if let run = store.activeRun {
                importProgress(run)
            } else if let paper = store.selectedPaper() {
                if player.turnCount > 0 {
                    PlayerBar(player: player,
                              onSeek: { player.seek(to: $0) },
                              activeTurn: player.activeTurn,
                              paper: paper)
                } else {
                    HStack(spacing: 8) {
                        Text("No audio yet").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text("Select a paper to listen").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func importProgress(_ p: Paper) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                Text(stageLabel(p.stage ?? "extract"))
                    .font(.callout.bold()).lineLimit(1)
                if let m = p.message {
                    Text(m).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if p.isError {
                    Button("Dismiss") { store.resetError(p.id) }.font(.callout)
                } else {
                    Text("\(Int((max(0.02, p.progress) * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(1, p.progress))
                .animation(.easeInOut(duration: 0.25), value: p.progress)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Highlight active word within a cue by current time
struct WordHighlighter: View {
    let tokens: [String]
    var body: some View { Text(joined) }
    private var joined: AttributedString {
        // Without live word timing, show plain text (words already space-joined).
        var a = AttributedString(tokens.joined(separator: " "))
        return a
    }
}

// MARK: - Transcript sheet
struct TranscriptView: View {
    let transcript: Transcript
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title3).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { si, seg in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(si + 1). \(seg.title)")
                                .font(.headline)
                            ForEach(Array(seg.turns.enumerated()), id: \.offset) { _, turn in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(turn.speaker + ":").font(.callout).fontWeight(.semibold)
                                        .frame(minWidth: 90, alignment: .trailing)
                                    Text(turn.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    if transcript.segments.isEmpty {
                        Text("No transcript yet.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 640, height: 560)
    }
}



// MARK: - Collapsible raw activity log pane (bottom of detail view)
struct LogPane: View {
    let lines: [String]
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack {
                    Image(systemName: "terminal").font(.caption)
                    Text("Activity log").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(lines.count) lines").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            if isOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(lines.isEmpty ? "No activity yet." : lines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .frame(maxHeight: 150)
                    .padding(10)
                    .onChange(of: lines.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}