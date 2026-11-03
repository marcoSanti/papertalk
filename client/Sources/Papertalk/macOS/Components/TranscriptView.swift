// The transcript sheet: the episode's script to read along, segment by segment, with copy.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Transcript sheet
/// The sheet for a loaded transcript, or a placeholder when the paper has none.
struct TranscriptSheetView: View {
    let item: AppStore.TranscriptSheet

    var body: some View {
        if let t = TranscriptPresentation.readable(item.transcript) {
            TranscriptView(transcript: t, title: item.title)
        } else {
            ContentUnavailableView(L("No transcript yet"), systemImage: "text.quote", description: Text(L("The transcript for this paper isn’t available.")))
                .frame(width: 700, height: 660)
        }
    }
}

/// Every segment with its turns, speakers marked by avatar; copies as plain text.
struct TranscriptView: View {
    let transcript: Transcript
    /// The paper's title, in the header.
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { si, seg in
                        segment(si, seg)
                    }
                    if transcript.segments.isEmpty {
                        ContentUnavailableView(L("No transcript yet"), systemImage: "text.quote")
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 700, height: 660)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(TranscriptPresentation.segmentCount(transcript))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(TranscriptPresentation.speakerNames(transcript).prefix(TranscriptPresentation.headerSpeakerLimit), id: \.self) { name in
                        HStack(spacing: 4) {
                            Circle().fill(Color.stable(for: name)).frame(width: 7, height: 7)
                            Text(name).font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(.regular, in: Capsule())
                    }
                }
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Copy transcript"))
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(L("Close"))
                }
            }
        }
        .padding(20)
    }

    /// One segment: number, title and its turns.
    private func segment(_ index: Int, _ seg: Transcript.Segment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(TranscriptPresentation.segmentNumber(index))
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.appAccent)
                Text(seg.title)
                    .font(.headline)
            }
            ForEach(Array(seg.turns.enumerated()), id: \.offset) { _, turn in
                HStack(alignment: .top, spacing: 12) {
                    Text(TranscriptPresentation.speakerInitial(turn.speaker))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.stable(for: turn.speaker).gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.stable(for: turn.speaker, saturation: 0.6, brightness: 0.7))
                        Text(turn.text)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Copy the whole transcript and show "Copied" for a moment.
    private func copyAll() {
        Clipboard.copy(TranscriptPresentation.plainText(transcript))
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.snappy) { copied = false }
        }
    }
}

#endif
