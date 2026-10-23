// The `.papertalk` paper bundle: one paper's folder (record, script, mind map, audio, PDF) as a
// package. Exports are written in it, imports read it, and the local library keeps every paper
// in one (see `LocalStorage`).

import Foundation

/// The files of a paper bundle and the rules for taking one in.
enum PaperBundle {
    /// The bundle's file extension.
    static let pathExtension = LocalStorage.packageExtension
    /// The bundle's uniform type (declared in the macOS Info.plist, a package).
    static let typeIdentifier = "dev.papertalk.paper"

    /// Whether `url` names a paper bundle.
    static func isBundle(_ url: URL) -> Bool { url.pathExtension.lowercased() == pathExtension }

    /// The storage keys a bundle of paper `id` holds, record first. `turns` is the number of
    /// baked turns (0 without audio); the manifest comes after them, as when baking.
    static func keys(_ id: String, turns: Int, includePDF: Bool) -> [String] {
        [K.paper(id), K.transcript(id), K.mindMap(id)]
            + (0..<turns).map { K.turn(id, $0) } + (turns > 0 ? [K.audioManifest(id)] : [])
            + (includePDF ? [K.pdf(id)] : [])
    }

    /// A key's path inside the bundle ("papers/<id>/turns/0.wav" → "turns/0.wav").
    static func relative(_ key: String, _ id: String) -> String { String(key.dropFirst(K.folder(id).count)) }

    /// The id an imported paper is stored under: its own when that's a free UUID (so a paper
    /// exported from this library and deleted comes back as it was), else a new one. The id
    /// names a folder, so anything that isn't a UUID is never used.
    static func importId(_ id: String, taken: (String) -> Bool) -> String {
        UUID(uuidString: id) != nil && !taken(id) ? id : UUID().uuidString
    }

    /// The record as imported: under `id`, with flags matching the files that came with it, and
    /// never mid-conversion (the library would resume it).
    static func imported(_ p: Paper, id: String, hasPdf: Bool, hasScript: Bool, hasAudio: Bool, hasMindMap: Bool) -> Paper {
        var p = p
        p.id = id
        p.hasPdf = hasPdf
        p.hasScript = hasScript
        p.hasAudio = hasAudio
        p.hasMindMap = hasMindMap
        if p.isActive || (p.isDone && !hasScript) {
            p.state = hasScript ? "done" : "error"
            p.stage = hasScript ? "done" : nil
            p.progress = 0
            p.message = nil
            p.statusError = hasScript ? nil : L("The imported file has no script. Rerun the episode to write one.")
        }
        return p
    }
}
