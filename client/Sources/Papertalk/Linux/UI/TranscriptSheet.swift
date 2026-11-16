// The Linux transcript sheet: the episode's script to read along, segment by segment, with copy.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// The episode script to read, shown as a sheet; a copy button and a close button in the
/// header, and a placeholder when the paper has no transcript yet.
struct TranscriptSheetView: View {
    var bridge: StoreBridge
    let sheet: AppStore.TranscriptSheet
    /// "Copied" appears briefly in the copy button after a copy, as on macOS.
    @State var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if let transcript = TranscriptPresentation.readable(sheet.transcript) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                            segmentView(index, segment)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                }
            } else {
                VStack(spacing: 8) {
                    Text(L("No transcript yet")).font(.headline)
                    Text(L("The transcript for this paper isn’t available."))
                        .foregroundColor(.gray)
                }
                .padding(40)
            }
        }
        .frame(width: 700, height: 660)
    }

    /// The paper's title, the speaker capsules and the copy / close buttons.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(sheet.title)
                    .font(.title3).fontWeight(.semibold)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let transcript = TranscriptPresentation.readable(sheet.transcript) {
                        Text(TranscriptPresentation.segmentCount(transcript))
                            .font(.caption).foregroundColor(.gray)
                        ForEach(TranscriptPresentation.speakerNames(transcript)
                            .prefix(TranscriptPresentation.headerSpeakerLimit), id: \.self) { name in
                            speakerCapsule(name)
                        }
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button(copied ? L("Copied") : L("Copy transcript")) { copyAll() }
                Button(L("Close")) { bridge.closeScriptSheet() }
            }
        }
        .padding(20)
    }

    /// A speaker's name with a dot in their stable colour.
    private func speakerCapsule(_ name: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(SpeakerPalette.color(for: name)).frame(width: 7, height: 7)
            Text(name).font(.caption).fontWeight(.medium)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    /// One segment: its number, title and turns.
    private func segmentView(_ index: Int, _ segment: Transcript.Segment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(TranscriptPresentation.segmentNumber(index))
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(.blue)
                Text(segment.title).font(.headline)
            }
            ForEach(Array(segment.turns.enumerated()), id: \.offset) { _, turn in
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .center) {
                        Circle().fill(SpeakerPalette.color(for: turn.speaker))
                            .frame(width: 26, height: 26)
                        Text(TranscriptPresentation.speakerInitial(turn.speaker))
                            .font(.caption).fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.speaker).font(.caption).fontWeight(.semibold)
                            .foregroundColor(.blue)
                        Text(turn.text).foregroundColor(.primary)
                    }
                }
            }
        }
    }

    /// Copy the whole transcript and show "Copied" for a moment.
    private func copyAll() {
        if let transcript = TranscriptPresentation.readable(sheet.transcript) {
            Clipboard.copy(TranscriptPresentation.plainText(transcript))
        }
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}
#endif