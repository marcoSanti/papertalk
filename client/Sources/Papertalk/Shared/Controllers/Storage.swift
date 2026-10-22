// Where the library's files live: the `Storage` protocol, its two backends (a folder in
// Application Support, or `server/storage_server.py` over HTTP), and the key layout `K` that
// names every file of a paper.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Picks the backend for a server configuration.
enum StorageFactory {
    /// Local storage without a server URL, else the HTTP store.
    static func make(config: ServerConfig) -> Storage {
        if config.apiBase.isEmpty { return LocalStorage() }
        return HttpStorage(apiBase: config.apiBase, token: config.token)
    }
}

// MARK: - Storage protocol

/// A flat key/value file store. Keys are paths like "papers/<id>/paper.json".
protocol Storage: AnyObject {
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
enum K {
    /// Everything belonging to one paper lives under this prefix.
    static func folder(_ id: String) -> String { "papers/\(id)/" }
    /// The folder holding every paper (Clear Data removes it).
    static let papersRoot = "papers/"
    /// Every `Library` (the user's folders of papers).
    static let libraries = "libraries.json"
    /// The library record (`Paper`).
    static func paper(_ id: String) -> String { "papers/\(id)/paper.json" }
    /// A script file older builds wrote; only deleted now.
    static func script(_ id: String) -> String { "papers/\(id)/script.json" }
    /// The episode script (`Transcript`).
    static func transcript(_ id: String) -> String { "papers/\(id)/transcript.json" }
    /// The mind map (`MindMap`).
    static func mindMap(_ id: String) -> String { "papers/\(id)/mindmap.json" }
    /// Unused: from an older audio format.
    static func captions(_ id: String) -> String { "papers/\(id)/captions.json" }
    /// Unused: from an older audio format (episodes are baked per turn now).
    static func audio(_ id: String) -> String { "papers/\(id)/podcast.m4a" }
    /// The imported PDF.
    static func pdf(_ id: String) -> String { "papers/\(id)/source.pdf" }
    /// Baked per-turn WAVs. `i` is the 0-based turn index.
    static func turn(_ id: String, _ i: Int) -> String { "papers/\(id)/turns/\(i).wav" }
    /// The durations of the baked turns (`AudioManifest`); written last, so its presence means the audio is complete.
    static func audioManifest(_ id: String) -> String { "papers/\(id)/audio.json" }
}

// MARK: - Local disk storage (self-hosted)
/// Files under `~/Library/Application Support/papertalk/`, the folder picked in Settings, or a
/// test's temp folder. Each paper's folder is a `.papertalk` package (`PaperBundle`), so Finder
/// shows it as one item; keys stay "papers/<id>/…" and `path(_:)` adds the extension.
final class LocalStorage: Storage {
    /// The library folder; keys are paths under it.
    let root: URL

    /// User defaults key of the library folder picked in Settings (absent: `defaultRoot`).
    static let folderDefaultsKey = "papertalk.libraryFolder"
    /// Application Support/papertalk.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("papertalk", isDirectory: true)
    }
    /// The picked library folder, else the default one.
    static var configuredRoot: URL {
        UserDefaults.standard.string(forKey: folderDefaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot
    }

    /// `root` pins the folder (tests); otherwise the configured one, moving an old "paper2pod" library over first.
    init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root ?? (UserDefaults.standard.string(forKey: Self.folderDefaultsKey) != nil ? Self.configuredRoot
            : LocalStorage.migrateLibrary(from: base.appendingPathComponent("paper2pod", isDirectory: true), to: Self.defaultRoot))
        self.root = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Move every paper package from the library at `old` into the one at `new`, keeping any
    /// paper `new` already has. Returns how many papers moved.
    @discardableResult
    static func moveLibrary(from old: URL, to new: URL) throws -> Int {
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
        if parts.count > 2, parts[0] == "papers", !parts[1].isEmpty { parts[1] += "." + PaperBundle.pathExtension }
        return root.appendingPathComponent(parts.joined(separator: "/"))
    }

    func read(_ key: String) async throws -> Data {
        try Data(contentsOf: path(key))
    }
    func write(_ key: String, _ data: Data) async throws {
        let p = path(key)
        try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: p, options: .atomic)
    }
    func delete(_ key: String) async throws {
        let p = path(key)
        if FileManager.default.fileExists(atPath: p.path) {
            try FileManager.default.removeItem(at: p)
        }
    }
    func deleteFolder(_ prefix: String) async throws {
        try await delete(prefix)   // a directory on disk: removed with its contents
    }
    /// Whether a file is there (without reading it).
    private func existsFile(_ path: URL) -> Bool {
        (try? path.checkResourceIsReachable()) ?? false
    }
    func list() async throws -> [String] {
        let base = root.appendingPathComponent("papers", isDirectory: true)
        guard var subs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        // Libraries from before packages have plain "<id>" folders: give them the extension.
        subs = subs.map { sub in
            var isDir: ObjCBool = false
            guard sub.pathExtension.isEmpty, !sub.lastPathComponent.hasPrefix("."),
                  FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { return sub }
            let package = sub.appendingPathExtension(PaperBundle.pathExtension)
            return (try? FileManager.default.moveItem(at: sub, to: package)) != nil ? package : sub
        }
        return subs.compactMap { $0.deletingPathExtension().lastPathComponent }
            .filter { existsFile(path(K.paper($0))) }
    }
    func url(for key: String) async -> URL? { path(key) }

    func exists<T: Decodable>(_ type: T.Type, _ key: String) async -> T? {
        guard let d = try? await read(key) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
    func save<T: Encodable>(_ value: T, _ key: String) async {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? await write(key, d)
    }
}

// MARK: - Remote HTTP storage (storage_server.py)
/// `server/storage_server.py`: GET/PUT/DELETE of keys, and GET of the root for the key list.
final class HttpStorage: Storage {
    /// The server's root URL.
    let base: URL
    /// Sent as a bearer token when not empty.
    let token: String

    init(apiBase: String, token: String) {
        // apiBase points at the storage server root, e.g. http://host:9170
        self.base = URL(string: apiBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression))!
        self.token = token
    }

    /// A request for `key`, with the token when there is one.
    private func request(_ key: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(key))
        req.httpMethod = method
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
    /// Throw unless the answer was a 2xx.
    private func check(_ r: URLResponse) throws {
        guard let http = r as? HTTPURLResponse else { throw StorageError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw StorageError.status(http.statusCode) }
    }

    func read(_ key: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: request(key, method: "GET"))
        try check(resp)
        return data
    }
    func write(_ key: String, _ data: Data) async throws {
        var req = request(key, method: "PUT")
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
    }
    func delete(_ key: String) async throws {
        let (_, resp) = try await URLSession.shared.data(for: request(key, method: "DELETE"))
        try check(resp)
    }
    func deleteFolder(_ prefix: String) async throws {
        // The server is a flat key store: delete every key under the prefix.
        let (data, resp) = try await URLSession.shared.data(for: request("", method: "GET"))
        try check(resp)
        let keys = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        for key in keys where key.hasPrefix(prefix) {
            try await delete(key)
        }
    }
    func list() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(for: request("", method: "GET"))
        try check(resp)
        // the server returns storage keys; extract paper ids
        let keys = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        let ids = keys.filter { $0.hasPrefix("papers/") && $0.hasSuffix("/paper.json") }
            .map { $0.dropFirst("papers/".count).dropLast("/paper.json".count) }
        return Array(Set(ids)).map(String.init)
    }
    func url(for key: String) async -> URL? {
        base.appendingPathComponent(key)
    }

    func exists<T: Decodable>(_ type: T.Type, _ key: String) async -> T? {
        guard let d = try? await read(key) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
    func save<T: Encodable>(_ value: T, _ key: String) async {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? await write(key, d)
    }
}

/// An HTTP store answer that wasn't a success.
enum StorageError: Error, LocalizedError {
    case badResponse, status(Int)
    var errorDescription: String? {
        switch self {
        case .badResponse: return L("Bad storage response")
        case .status(let c): return L("Storage returned {0}", c)
        }
    }
}