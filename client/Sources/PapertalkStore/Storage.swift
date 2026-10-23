// Where the library's files live: the `Storage` protocol, the key layout `K` that names every
// file of a paper, and `LocalStorage`, a library folder on disk. Shared by the app and the
// storage server (`StorageServer`), which serves a `LocalStorage` folder over HTTP.

import Foundation

// MARK: - Storage protocol

/// A flat key/value file store. Keys are paths like "papers/<id>/paper.json".
public protocol Storage: AnyObject {
    /// The bytes stored under `key`; throws when there are none.
    func read(_ key: String) async throws -> Data
    /// Store `data` under `key`, replacing what was there.
    func write(_ key: String, _ data: Data) async throws
    /// Remove `key`; a missing key isn't an error locally.
    func delete(_ key: String) async throws
    /// Remove every key under `prefix` (a folder such as "papers/<id>/").
    func deleteFolder(_ prefix: String) async throws
    /// The ids of every paper with a `paper.json`.
    func list() async throws -> [String]
    /// A playable/addressable URL for a stored key (file:// for local, http:// for remote).
    func url(for key: String) async -> URL?

    /// The JSON value under `key`, nil when it's missing or doesn't decode.
    func exists<T: Decodable>(_ type: T.Type, _ key: String) async -> T?
    /// Store `value` as JSON; failures are ignored (best-effort saves).
    func save<T: Encodable>(_ value: T, _ key: String) async
}

/// The storage key of every file the app writes.
public enum K {
    /// Everything belonging to one paper lives under this prefix.
    public static func folder(_ id: String) -> String { "papers/\(id)/" }
    /// The folder holding every paper (Clear Data removes it).
    public static let papersRoot = "papers/"
    /// Every `Library` (the user's folders of papers).
    public static let libraries = "libraries.json"
    /// The library record (`Paper`).
    public static func paper(_ id: String) -> String { "papers/\(id)/paper.json" }
    /// A script file older builds wrote; only deleted now.
    public static func script(_ id: String) -> String { "papers/\(id)/script.json" }
    /// The episode script (`Transcript`).
    public static func transcript(_ id: String) -> String { "papers/\(id)/transcript.json" }
    /// The mind map (`MindMap`).
    public static func mindMap(_ id: String) -> String { "papers/\(id)/mindmap.json" }
    /// Unused: from an older audio format.
    public static func captions(_ id: String) -> String { "papers/\(id)/captions.json" }
    /// Unused: from an older audio format (episodes are baked per turn now).
    public static func audio(_ id: String) -> String { "papers/\(id)/podcast.m4a" }
    /// The imported PDF.
    public static func pdf(_ id: String) -> String { "papers/\(id)/source.pdf" }
    /// Baked per-turn WAVs. `i` is the 0-based turn index.
    public static func turn(_ id: String, _ i: Int) -> String { "papers/\(id)/turns/\(i).wav" }
    /// The durations of the baked turns (`AudioManifest`); written last, so its presence means the audio is complete.
    public static func audioManifest(_ id: String) -> String { "papers/\(id)/audio.json" }
}

// MARK: - Local disk storage (self-hosted)
/// Files under `~/Library/Application Support/papertalk/`, the folder picked in Settings, or a
/// test's temp folder. Each paper's folder is a `.papertalk` package (`PaperBundle`), so Finder
/// shows it as one item; keys stay "papers/<id>/…" and `path(_:)` adds the extension.
public final class LocalStorage: Storage {
    /// The library folder; keys are paths under it.
    public let root: URL

    /// The extension of a paper's folder: a `.papertalk` package (`PaperBundle`).
    public static let packageExtension = "papertalk"
    /// User defaults key of the library folder picked in Settings (absent: `defaultRoot`).
    public static let folderDefaultsKey = "papertalk.libraryFolder"
    /// Application Support/papertalk.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("papertalk", isDirectory: true)
    }
    /// The picked library folder, else the default one.
    public static var configuredRoot: URL {
        UserDefaults.standard.string(forKey: folderDefaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot
    }

    /// `root` pins the folder (tests); otherwise the configured one, moving an old "paper2pod" library over first.
    public init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root ?? (UserDefaults.standard.string(forKey: Self.folderDefaultsKey) != nil ? Self.configuredRoot
            : LocalStorage.migrateLibrary(from: base.appendingPathComponent("paper2pod", isDirectory: true), to: Self.defaultRoot))
        self.root = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Move every paper package from the library at `old` into the one at `new`, keeping any
    /// paper `new` already has. Returns how many papers moved.
    @discardableResult
    public static func moveLibrary(from old: URL, to new: URL) throws -> Int {
        let fm = FileManager.default
        let from = old.appendingPathComponent("papers", isDirectory: true)
        let to = new.appendingPathComponent("papers", isDirectory: true)
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard from.standardizedFileURL != to.standardizedFileURL,
              let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return 0 }
        var moved = 0
        for item in items where !fm.fileExists(atPath: to.appendingPathComponent(item.lastPathComponent).path) {
            try fm.moveItem(at: item, to: to.appendingPathComponent(item.lastPathComponent))
            moved += 1
        }
        return moved
    }

    /// First launch under the new name: move an existing library written under
    /// the old "paper2pod" folder into "papertalk" so saved papers survive.
    private static func migrateLibrary(from old: URL, to new: URL) -> URL {
        let oldRoot = old.appendingPathComponent("library", isDirectory: true)
        if !FileManager.default.fileExists(atPath: oldRoot.path) { return new }
        if FileManager.default.fileExists(atPath: new.path) {
            // New dir already present — leave the old one alone.
            return new
        }
        try? FileManager.default.moveItem(at: oldRoot, to: new)
        // Clean up the now-empty old parent directory.
        try? FileManager.default.removeItem(at: old)
        return new
    }

    /// The file for `key`: "papers/<id>/…" lives in "papers/<id>.papertalk/…".
    private func path(_ key: String) -> URL {
        var parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2, parts[0] == "papers", !parts[1].isEmpty { parts[1] += "." + Self.packageExtension }
        return root.appendingPathComponent(parts.joined(separator: "/"))
    }

    public func read(_ key: String) async throws -> Data {
        try Data(contentsOf: path(key))
    }
    public func write(_ key: String, _ data: Data) async throws {
        let p = path(key)
        try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: p, options: .atomic)
    }
    public func delete(_ key: String) async throws {
        let p = path(key)
        if FileManager.default.fileExists(atPath: p.path) {
            try FileManager.default.removeItem(at: p)
        }
    }
    public func deleteFolder(_ prefix: String) async throws {
        try await delete(prefix)   // a directory on disk: removed with its contents
    }
    /// Whether a file is there (without reading it).
    private func existsFile(_ path: URL) -> Bool {
        (try? path.checkResourceIsReachable()) ?? false
    }
    public func list() async throws -> [String] {
        adoptPlainFolders().compactMap { $0.deletingPathExtension().lastPathComponent }
            .filter { existsFile(path(K.paper($0))) }
    }

    /// Libraries from before packages (and the old Python storage server's roots) have plain "<id>" paper
    /// folders: give them the extension. Returns every folder in "papers/".
    @discardableResult
    public func adoptPlainFolders() -> [URL] {
        let base = root.appendingPathComponent("papers", isDirectory: true)
        guard let subs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return subs.map { sub in
            var isDir: ObjCBool = false
            guard sub.pathExtension.isEmpty, !sub.lastPathComponent.hasPrefix("."),
                  FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { return sub }
            let package = sub.appendingPathExtension(Self.packageExtension)
            return (try? FileManager.default.moveItem(at: sub, to: package)) != nil ? package : sub
        }
    }

    /// Every stored file's key, sorted, hidden files left out (an atomic save's temporary file,
    /// .DS_Store): what the storage server lists.
    public func allKeys() -> [String] {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var keys: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let file = url.resolvingSymlinksInPath().path
            guard file.hasPrefix(base + "/") else { continue }
            var parts = file.dropFirst(base.count + 1).split(separator: "/").map(String.init)
            let package = "." + Self.packageExtension
            if parts.count > 2, parts[0] == "papers", parts[1].hasSuffix(package) { parts[1].removeLast(package.count) }
            keys.append(parts.joined(separator: "/"))
        }
        return keys.sorted()
    }
    public func url(for key: String) async -> URL? { path(key) }

    public func exists<T: Decodable>(_ type: T.Type, _ key: String) async -> T? {
        guard let d = try? await read(key) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
    public func save<T: Encodable>(_ value: T, _ key: String) async {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? await write(key, d)
    }
}
