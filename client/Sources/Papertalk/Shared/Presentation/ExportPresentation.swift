// What an exported episode is called and the tags written into it: the suggested file name and
// the metadata fields, built from the paper's record so the encoder only copies them over.

import Foundation

/// The file name and tags of an exported episode (see `AppStore.exportAudio`).
struct EpisodeExport: Equatable {
    var title: String
    /// The authors, in byline order.
    var artist: String
    var album = "Papertalk"
    var genre = "Podcast"
    /// The publication year, when known.
    var year: String?
    /// Affiliations, DOI, publication date and tags, one per line.
    var comment: String

    init(paper p: Paper) {
        title = p.displayTitle
        artist = p.authors.joined(separator: ", ")
        year = p.publishedIso.map { String($0.prefix(4)) }
        var lines: [String] = []
        if !p.affiliations.isEmpty { lines.append("Affiliations: " + p.affiliations.joined(separator: "; ")) }
        if !p.doi.isEmpty { lines.append("DOI: https://doi.org/" + p.doi) }
        if let date = p.publishedIso { lines.append("Published: " + date) }
        if !p.tags.isEmpty { lines.append("Tags: " + p.tags.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")) }
        comment = lines.joined(separator: "\n")
    }

    /// Only a fully voiced paper that isn't being converted has a track to export.
    static func canExport(_ p: Paper) -> Bool { p.hasAudio && !p.isActive }

    /// The paper's title as an .m4a file name.
    static func fileName(_ p: Paper) -> String { PaperPresentation.fileName(p, extension: "m4a") }
}
