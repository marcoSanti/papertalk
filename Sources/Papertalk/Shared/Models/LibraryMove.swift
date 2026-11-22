// Moving the local library to another folder: its papers, and the two files beside them.

import Foundation

extension LocalStorage {
    /// Move the library at `old` into `new`. What `new` already holds wins: its papers stay, and
    /// its libraries and suggestions gain the moved ones. Both folders' indexes are read before
    /// anything changes, and `old`'s are removed last, so a failure part way loses nothing.
    /// Returns how many papers moved.
    @discardableResult
    static func moveLibrary(from old: URL, to new: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        // A link or another spelling of the same folder: removing "the old" files would remove the library's.
        guard !isSameFolder(old, new) else { return 0 }

        let libraries = try joined(K.libraries, from: old, to: new) { (mine: [Library], theirs: [Library]) in
            theirs + mine.filter { library in !theirs.contains { $0.id == library.id } }
        }
        let suggestions = try joined(K.suggestions, from: old, to: new) { (mine: SuggestionLog, theirs: SuggestionLog) in
            theirs.joined(with: mine)
        }
        let files = [(K.libraries, libraries), (K.suggestions, suggestions)]
        for case let (key, data?) in files { try data.write(to: new.appendingPathComponent(key), options: .atomic) }
        let moved = try movePapers(from: old, to: new)
        // The move is done by now: a file that won't go mustn't report it failed (moving back merges it).
        for case let (key, _?) in files { try? fm.removeItem(at: old.appendingPathComponent(key)) }
        return moved
    }

    /// What `new` should hold under `key`; nil when `old` has nothing to bring.
    private static func joined<T: Codable>(_ key: String, from old: URL, to new: URL, _ join: (T, T) -> T) throws -> Data? {
        guard let mine = try contents(of: old.appendingPathComponent(key)) else { return nil }
        guard let theirs = try contents(of: new.appendingPathComponent(key)) else { return mine }
        let decoder = JSONDecoder()
        return try JSONEncoder().encode(join(decoder.decode(T.self, from: mine), decoder.decode(T.self, from: theirs)))
    }

    /// Whether the two paths are one folder on disk.
    private static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        func identity(_ url: URL) -> [Int]? {
            guard let info = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
                  let volume = info[.systemNumber] as? Int, let file = info[.systemFileNumber] as? Int else { return nil }
            return [volume, file]
        }
        guard let first = identity(a) else { return false }
        return first == identity(b)
    }
}
