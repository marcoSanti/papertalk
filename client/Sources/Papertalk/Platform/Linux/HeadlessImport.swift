#if os(Linux)
import Foundation

/// `Papertalk --import paper.pdf [--depth summary|in_depth] [--library DIR]`:
/// runs a whole import without a window, answering the "already in library"
/// question with yes and the cast question with the model's proposal. It
/// exercises the real pipeline (PDF → LLM → Kokoro → WAV) on Linux; the LLM
/// comes from the usual settings or LLM_BASE_URL / PAPERTALK_MODEL.
@MainActor
enum HeadlessImport {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let path = value(after: "--import", in: arguments) else { return usage() }
        let depth = value(after: "--depth", in: arguments).flatMap(Depth.init(rawValue:)) ?? .summary
        guard let pdf = FileManager.default.contents(atPath: path) else {
            print("Could not read \(path)")
            return 1
        }
        let store = value(after: "--library", in: arguments).map {
            AppStore(storage: LocalStorage(root: URL(fileURLWithPath: $0, isDirectory: true)))
        } ?? AppStore()
        // Let the startup scan of the library finish before importing.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let before = Set(store.papers.keys)
        store.upload(pdf, filename: URL(fileURLWithPath: path).lastPathComponent, depth: depth, depthNote: "")

        var id: String?
        var lastLine = ""
        while true {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if store.pendingDuplicate != nil { store.resolveDuplicate(true) }
            if let cast = store.pendingCast {
                let form = CastForm(proposals: cast.proposals, authors: cast.authors, authorGenders: cast.authorGenders)
                print("Cast: " + form.cast.map { "\($0.name) (\($0.voice))" }.joined(separator: ", "))
                store.resolveCast(form.cast)
            }
            id = id ?? store.papers.keys.first { !before.contains($0) }
            guard let id, let paper = store.papers[id] else { continue }
            let line = "[\(Int(paper.progress * 100))%] \(paper.stage ?? "") \(paper.message ?? "")"
            if line != lastLine { print(line); lastLine = line }
            if paper.isDone {
                print("Done: \(paper.displayTitle) (id \(id))")
                return 0
            }
            if paper.isError {
                print("Failed: \(paper.statusError ?? "unknown error")")
                return 1
            }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func usage() -> Int32 {
        print("usage: Papertalk --import paper.pdf [--depth summary|in_depth] [--library DIR]")
        return 2
    }
}
#endif
