// Picking the library's storage backend, and the HTTP one: `HttpStorage`, the client of the
// storage server (`StorageServer`). The protocol, the key layout `K` and the local folder
// (`LocalStorage`) live in the PapertalkStore module, shared with the server.

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
        self.base = URL(string: apiBase.withoutTrailingSlashes)!
        self.token = token
    }

    /// A request for `key`, with the token when there is one.
    private func request(_ key: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(key))
        req.httpMethod = method
        req.setBearer(token)
        return req
    }
    /// The answer's body; throws unless it was a 2xx.
    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let status = resp.httpStatus else { throw StorageError.badResponse }
        guard resp.isSuccess else { throw StorageError.status(status) }
        return data
    }

    /// Every key on the server.
    private func allKeys() async throws -> [String] {
        let data = try await send(request("", method: "GET"))
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func read(_ key: String) async throws -> Data {
        try await send(request(key, method: "GET"))
    }
    func write(_ key: String, _ data: Data) async throws {
        var req = request(key, method: "PUT")
        req.httpBody = data
        try await send(req)
    }
    func delete(_ key: String) async throws {
        try await send(request(key, method: "DELETE"))
    }
    func deleteFolder(_ prefix: String) async throws {
        // The server is a flat key store: delete every key under the prefix.
        for key in try await allKeys() where key.hasPrefix(prefix) {
            try await delete(key)
        }
    }
    func list() async throws -> [String] {
        // the server returns storage keys; extract paper ids
        let keys = try await allKeys()
        let ids = keys.filter { $0.hasPrefix(K.papersRoot) && $0.hasSuffix("/paper.json") }
            .map { $0.dropFirst(K.papersRoot.count).dropLast("/paper.json".count) }
        return Array(Set(ids)).map(String.init)
    }
    func url(for key: String) async -> URL? {
        base.appendingPathComponent(key)
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