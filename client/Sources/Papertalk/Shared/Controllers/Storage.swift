// Picking the library's storage backend, and the HTTP one: `HttpStorage`, the client of the
// storage server (`StorageServer`). The protocol, the key layout `K` and the local folder
// (`LocalStorage`) live in the PapertalkStore module, shared with the server.

@_exported import PapertalkStore
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

// MARK: - Remote HTTP storage (PapertalkServer)
/// The storage server (`StorageServer`): GET/PUT/DELETE of keys, and GET of the root for the key list.
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