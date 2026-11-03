// The storage server: a library folder (`LocalStorage`) served over HTTP, so copies of the app on
// several machines can share one library (`HttpStorage` is its client). It only stores files;
// conversion always runs in the app. `PapertalkServer` runs it from the command line.

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Serves a `LocalStorage` folder over HTTP/1.1, one request per connection:
///   GET /          the stored keys (JSON array, sorted)
///   GET /<key>     the key's bytes
///   HEAD /<key>    whether it exists, with its size
///   PUT /<key>     store the request body under the key
///   DELETE /<key>  remove the key (no error when it's missing)
/// Keys are URL-encoded paths such as "papers/<id>/paper.json". With a token, every request
/// needs "Authorization: Bearer <token>".
public final class StorageServer: @unchecked Sendable {
    /// The library folder served; the same layout as the app's own library.
    public let storage: LocalStorage
    /// The port it listens on (the one the system picked, when asked for 0).
    public let port: Int
    private let token: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false

    /// Requests that stall for this long are dropped.
    static let timeoutSeconds = 30
    /// A request's line and headers may not be longer than this.
    static let maxHeaderBytes = 64 * 1024

    /// Binds `host:port` (0: any free port) and adopts a root written by the old Python server.
    public init(root: URL, host: String = "0.0.0.0", port: Int = 9170, token: String = "") throws {
        storage = LocalStorage(root: root)
        // storage_server.py kept papers in plain "papers/<id>/" folders; the app's layout is packages.
        storage.adoptPlainFolders()
        self.token = token
        listener = try Self.openListener(host: host, port: port)
        self.port = Self.boundPort(listener)
    }

    /// Accept connections until `stop()`; each one is answered on its own task.
    public func run() {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            // Poll rather than block in accept, so stop() is noticed within a quarter second.
            guard poll(&pfd, 1, 250) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Self.configure(client)
            // shortcut: blocking socket I/O on the cooperative pool, so at most about one transfer per
            // CPU core runs at once (others wait); move to SwiftNIO if many clients share one server.
            Task.detached { await self.serve(client) }
        }
        close(listener)
    }

    /// `run()` on a background thread (tests).
    public func start() {
        Thread.detachNewThread { self.run() }
    }

    /// Stop accepting connections; the listening socket closes within a quarter second.
    public func stop() { lock.withLock { stopped = true } }
    private var isStopped: Bool { lock.withLock { stopped } }

    // MARK: Requests

    /// One parsed request.
    struct Request {
        let method: String
        /// The path, URL-decoded, without the query or leading slashes ("" for the root).
        let path: String
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
    }

    /// One reply: a status and a body, or for HEAD only the length the body would have.
    struct Response: Equatable {
        let status: Int
        var contentType = "application/json"
        var body = Data()
        /// HEAD's Content-Length (the body itself isn't sent).
        var length: Int?

        static func json(_ value: some Encodable, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return Response(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
        }
        static func error(_ status: Int, _ message: String) -> Response { .json(["error": message], status: status) }
    }

    /// Read a request, answer it, close the connection.
    private func serve(_ fd: Int32) async {
        defer { close(fd) }
        guard let request = Self.readRequest(fd) else {
            Self.reply(.error(400, "bad request"), to: fd, head: false)
            return
        }
        Self.reply(await respond(request), to: fd, head: request.method == "HEAD")
    }

    /// The answer to `r`.
    func respond(_ r: Request) async -> Response {
        guard isAuthorized(r.headers["authorization"]) else { return .error(401, "unauthorized") }
        guard !r.path.isEmpty else {
            switch r.method {
            case "GET": return .json(storage.allKeys())
            case "PUT", "DELETE": return .error(400, "missing key")
            default: return .error(404, "not found")
            }
        }
        let key = r.path
        guard Self.isValidKey(key) else { return .error(400, "bad key") }
        switch r.method {
        case "GET":
            guard let data = try? await storage.read(key) else { return .error(404, "not found") }
            return Response(status: 200, contentType: "application/octet-stream", body: data)
        case "HEAD":
            guard let size = await fileSize(key) else { return Response(status: 404, length: 0) }
            return Response(status: 200, contentType: "application/octet-stream", length: size)
        case "PUT":
            do {
                try await storage.write(key, r.body)
                return .json(["key": key])
            } catch {
                return .error(500, "could not store \(key)")
            }
        case "DELETE":
            // Only files: a key never names a folder, so "DELETE /papers" can't empty the library.
            if await fileSize(key) != nil { try? await storage.delete(key) }
            return .json([String: String]())
        default:
            return .error(501, "unsupported method")
        }
    }

    /// No token set, or the request carries it (compared in constant time).
    private func isAuthorized(_ header: String?) -> Bool {
        guard !token.isEmpty else { return true }
        let given = Array((header ?? "").utf8), wanted = Array("Bearer \(token)".utf8)
        guard given.count == wanted.count else { return false }
        return zip(given, wanted).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The size of the regular file stored under `key`; nil when there's none.
    private func fileSize(_ key: String) async -> Int? {
        guard let url = await storage.url(for: key),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize ?? 0
    }

    /// Keys are relative paths whose parts are never empty or hidden: no "..", no absolute
    /// paths, so nothing outside the root can be read or written.
    static func isValidKey(_ key: String) -> Bool {
        !key.contains("\0") && key.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// The request line, headers and body read from `fd`; nil when they're malformed.
    static func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard buffer.count <= maxHeaderBytes, let chunk = receive(fd) else { return nil }
            buffer.append(chunk)
            headerEnd = buffer.range(of: separator)
        }
        guard let end = headerEnd, let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        guard let parsed = parseHead(head) else { return nil }
        var body = Data(buffer[end.upperBound...])
        let length = Int(parsed.headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return nil }
        while body.count < length {
            guard let chunk = receive(fd) else { return nil }
            body.append(chunk)
        }
        return Request(method: parsed.method, path: parsed.path, headers: parsed.headers, body: body.prefix(length))
    }

    /// The method, decoded path and headers of a request's head; nil when malformed.
    static func parseHead(_ head: String) -> (method: String, path: String, headers: [String: String])? {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else { return nil }
        let target = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(target).removingPercentEncoding else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(decoded.drop { $0 == "/" })
        return (String(requestLine[0]), path, headers)
    }

    /// Write `r` to `fd` (without the body for HEAD).
    static func reply(_ r: Response, to fd: Int32, head: Bool) {
        var text = "HTTP/1.1 \(r.status) \(reason(r.status))\r\n"
        text += "Content-Type: \(r.contentType)\r\n"
        text += "Content-Length: \(r.length ?? r.body.count)\r\n"
        text += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(text.utf8)), !head else { return }
        _ = sendAll(fd, r.body)
    }

    /// The reason phrase after a status code.
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 501: "Not Implemented"
        default: "Internal Server Error"
        }
    }

    // MARK: Sockets

    /// A listening TCP socket on `host:port`.
    private static func openListener(host: String, port: Int) throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ServerError.socket("socket", errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd)
            throw ServerError.badHost(host)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.socket("bind", code)
        }
        return fd
    }

    /// The port `fd` is bound to.
    private static func boundPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Time out stalled clients; on macOS, don't let a closed connection kill the process.
    private static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Up to 64 KB from `fd`; nil at the end, on error or timeout.
    private static func receive(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(fd, &bytes, bytes.count, 0)
        return n > 0 ? Data(bytes[..<n]) : nil
    }

    /// Write all of `data`; false when the client went away.
    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress! + offset, raw.count - offset, flags)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}

/// Why the server couldn't start.
public enum ServerError: Error, CustomStringConvertible {
    case badHost(String), socket(String, Int32)
    public var description: String {
        switch self {
        case .badHost(let h): "Not an IPv4 address: \(h)"
        case .socket(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}
