#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Transcript sheet
struct TranscriptView: View {
    let transcript: Transcript
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
                        ContentUnavailableView("No transcript yet", systemImage: "text.quote")
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
                    ForEach(TranscriptPresentation.speakerNames(transcript).prefix(4), id: \.self) { name in
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
                    .help("Copy transcript")
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
            }
        }
        .padding(20)
    }

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
