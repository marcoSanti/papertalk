// Exporting a paper's baked episode as one audio file (macOS: the encoder is AVFoundation).

#if os(macOS)
import AppKit
import Foundation

extension AppStore {
    /// Join the baked turns into one M4A at `url`, tagged from the paper's record, with the
    /// PDF's first page as cover art. Reports the outcome as a toast.
    func exportAudio(_ id: String, to url: URL) async {
        guard let paper = papers[id], let turns = await loadBakedAudio(for: id), !turns.isEmpty else {
            show(L("This paper has no saved audio to export. Regenerate audio first."))
            return
        }
        let cover = await loadThumbnail(id)?.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        do {
            try await AudioExport.writeM4A(wav: KokoroSpeech.joinWAVs(turns.map(\.wav)),
                                           tags: EpisodeExport(paper: paper), artwork: cover, to: url)
            show(L("Exported “{0}”", url.lastPathComponent))
        } catch {
            show(L("Couldn't export the audio: {0}", error.localizedDescription))
        }
    }
}
#endif
