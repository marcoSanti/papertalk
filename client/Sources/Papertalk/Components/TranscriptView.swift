import SwiftUI

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