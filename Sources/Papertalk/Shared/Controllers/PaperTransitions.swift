// Changes of a paper's state that leave a message on its record, in the interface's language.

import Foundation

extension Paper {
    /// The conversion's end: done, at 100%.
    mutating func markDone() {
        state = "done"; stage = "done"; progress = 1; message = L("Done")
    }

    /// A copy with the error acknowledged: back to "done" when an earlier
    /// episode is still on disk, otherwise an unconverted "draft".
    func dismissingError() -> Paper {
        var p = self
        if hasScript {
            p.markDone()
        } else {
            p.state = "draft"; p.stage = nil; p.progress = 0; p.message = nil
        }
        p.statusError = nil
        return p
    }
}

extension PaperBundle {
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
