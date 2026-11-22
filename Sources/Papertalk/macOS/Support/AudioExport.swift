// Encoding a whole episode to one tagged AAC (.m4a) file on macOS, through AVFoundation.

#if os(macOS)
import AVFoundation
import Foundation

/// Writes an episode WAV as an M4A with iTunes tags. AAC, not MP3: macOS has no MP3
/// encoder, and M4A carries the same tags (and cover art) in every player.
enum AudioExport {
    /// Encode `wav` to `url`, replacing what's there (the save panel already asked).
    static func writeM4A(wav: Data, tags: EpisodeExport, artwork: Data?, to url: URL) async throws {
        // The export session reads from a file.
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("papertalk-export-\(UUID().uuidString).wav")
        try wav.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source),
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechAudio.Failure.unreadable
        }
        session.metadata = metadata(tags, artwork: artwork)
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .m4a)
    }

    /// The tags as iTunes metadata items; empty fields are left out.
    static func metadata(_ tags: EpisodeExport, artwork: Data?) -> [AVMetadataItem] {
        var fields: [(AVMetadataIdentifier, String?)] = [
            (.iTunesMetadataSongName, tags.title),
            (.iTunesMetadataArtist, tags.artist),
            (.iTunesMetadataAlbumArtist, tags.artist),
            (.iTunesMetadataAlbum, tags.album),
            (.iTunesMetadataUserGenre, tags.genre),
            (.iTunesMetadataReleaseDate, tags.year),
            (.iTunesMetadataUserComment, tags.comment),
            (.iTunesMetadataEncodingTool, "Papertalk"),
        ]
        fields.removeAll { $0.1?.isEmpty ?? true }
        var items: [AVMetadataItem] = fields.map { id, value in
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString?
            return item
        }
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = artwork as NSData
            item.dataType = kCMMetadataBaseDataType_PNG as String
            items.append(item)
        }
        return items
    }
}
#endif
