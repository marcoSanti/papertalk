import Foundation

// MARK: - Server configuration (persisted in the app)
struct ServerConfig: Codable, Equatable {
    var apiBase: String
    var token: String

    static func load() -> ServerConfig {
        let defaults = UserDefaults.standard
        let envBase = ProcessInfo.processInfo.environment["PAPERTALK_SERVER_URL"] ?? ""
        let envToken = ProcessInfo.processInfo.environment["PAPERTALK_API_TOKEN"] ?? ""
        if let raw = defaults.string(forKey: "papertalk.server.json"),
           let data = raw.data(using: .utf8),
           let c = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            return c
        }
        return ServerConfig(apiBase: envBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression), token: envToken)
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "papertalk.server.json")
        }
    }
}

// MARK: - LLM settings for the in-process pipeline (persisted locally)
struct LLMSettings: Codable, Equatable {
    var baseUrl: String
    var apiKey: String
    var model: String
    /// Optional env var name whose value supplies the API key at request time.
    /// When set, `apiKey` is ignored and the key is never persisted.
    var keyEnv: String

    /// The effective API key: env var wins when one is selected.
    func resolvedKey() -> String {
        if !keyEnv.isEmpty, let v = ProcessInfo.processInfo.environment[keyEnv], !v.isEmpty {
            return v
        }
        return apiKey
    }

    static func load() -> LLMSettings {
        // Stored value wins; otherwise seed from the environment.
        if let raw = UserDefaults.standard.string(forKey: "papertalk.llm.json"),
           let data = raw.data(using: .utf8),
           let s = try? JSONDecoder().decode(LLMSettings.self, from: data) {
            return s
        }
        let env = ProcessInfo.processInfo.environment
        let keyEnv = firstSet(env, ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY"])
        return LLMSettings(baseUrl: env["OPENWEBUI_BASE_URL"] ?? env["LLM_BASE_URL"] ?? "",
                           apiKey: "",
                           model: env["PAPERTALK_MODEL"] ?? "",
                           keyEnv: keyEnv)
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "papertalk.llm.json")
        }
    }
}

/// Names of environment variables that (when set) look like current API keys,
/// offered in the settings sheet as selectable key sources.
func candidateKeyEnvs() -> [String] {
    let env = ProcessInfo.processInfo.environment
    return ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY"]
        .filter { !(env[$0] ?? "").isEmpty }
}

private func firstSet(_ env: [String: String], _ keys: [String]) -> String {
    keys.first { !(env[$0] ?? "").isEmpty } ?? ""
}

enum StorageFactory {
    static func make(config: ServerConfig) -> Storage {
        if config.apiBase.isEmpty { return LocalStorage() }
        return HttpStorage(apiBase: config.apiBase, token: config.token)
    }
}

// MARK: - Storage: where paper artifacts live. Local disk (self-host) or an
// HTTP storage server (network without SMB). Matches server/storage_server.py.

protocol Storage: AnyObject {
    func read(_ key: String) async throws -> Data
    func write(_ key: String, _ data: Data) async throws
    func delete(_ key: String) async throws
    func list() async throws -> [String]
    /// A playable/addressable URL for a stored key (file:// for local, http:// for remote).
    func url(for key: String) async -> URL?

    func exists<T: Decodable>(_ type: T.Type, _ key: String) async -> T?
    func save<T: Encodable>(_ value: T, _ key: String) async
}

// Keys / artifact layout.
enum K {
    static func paper(_ id: String) -> String { "papers/\(id)/paper.json" }
    static func script(_ id: String) -> String { "papers/\(id)/script.json" }
    static func transcript(_ id: String) -> String { "papers/\(id)/transcript.json" }
    static func captions(_ id: String) -> String { "papers/\(id)/captions.json" }
    static func audio(_ id: String) -> String { "papers/\(id)/podcast.m4a" }
    static func pdf(_ id: String) -> String { "papers/\(id)/source.pdf" }
    /// Baked per-turn WAVs. `i` is the 0-based turn index.
    static func turn(_ id: String, _ i: Int) -> String { "papers/\(id)/turns/\(i).wav" }
    static func audioManifest(_ id: String) -> String { "papers/\(id)/audio.json" }
}

// MARK: - Local disk storage (self-hosted)
final class LocalStorage: Storage {
    let root: URL

    init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root ?? LocalStorage.migrateLibrary(from: base.appendingPathComponent("paper2pod", isDirectory: true),
                                         to: base.appendingPathComponent("papertalk", isDirectory: true))
        self.root = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    private func path(_ key: String) -> URL { root.appendingPathComponent(key) }

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
    private func existsFile(_ path: URL) -> Bool {
        (try? path.checkResourceIsReachable()) ?? false
    }
    func list() async throws -> [String] {
        let base = root.appendingPathComponent("papers", isDirectory: true)
        guard let subs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
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
final class HttpStorage: Storage {
    let base: URL
    let token: String

    init(apiBase: String, token: String) {
        // apiBase points at the storage server root, e.g. http://host:9170
        self.base = URL(string: apiBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression))!
        self.token = token
    }

    private func request(_ key: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(key))
        req.httpMethod = method
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
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

enum StorageError: Error, LocalizedError {
    case badResponse, status(Int)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "Bad storage response"
        case .status(let c): return "Storage returned \(c)"
        }
    }
}