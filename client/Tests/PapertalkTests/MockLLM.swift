import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk

/// Stand-in LLM server. Registers a `URLProtocol` so `URLSession.shared` calls
/// made by `LocalPipeline`'s `chat`/`send` are answered in-process instead of
/// hitting the network. The test decides what the model says by inspecting each
/// request's body and returning a canned reply.
final class MockLLM {
    static var onRequest: ((URLRequest) -> (status: Int, body: Data))?
    /// Paths (substrings of the user prompt) seen by the mock, for assertions.
    private(set) static var seen: Set<String> = []

    private final class StubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            defer { client?.urlProtocolDidFinishLoading(self) }
            guard let reply = MockLLM.onRequest?(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            // A negative status stands for a server that can't be reached.
            if reply.status < 0 {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let resp = HTTPURLResponse(url: request.url!,
                                       statusCode: reply.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
        }
        override func stopLoading() {}
    }

    /// Install the interceptor. Each call replaces the previous handler.
    static func install(_ handler: @escaping (URLRequest) -> (status: Int, body: Data)) {
        onRequest = handler
        seen = []
        _ = URLProtocol.registerClass(StubURLProtocol.self)
    }

    /// Record that a request whose user prompt contains `flag` was made.
    static func note(flag: String) { seen.insert(flag) }

    static func uninstall() {
        onRequest = nil
        URLProtocol.unregisterClass(StubURLProtocol.self)
    }

    // MARK: body helpers

    /// Read the request body. URLSession can expose it as a stream instead of
    /// the `httpBody` property inside a `URLProtocol`.
    static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var out = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            guard n > 0 else { break }
            out.append(buf, count: n)
        }
        return out
    }

    /// All message text (system + user) of a chat request, for needle matching.
    static func allText(in request: URLRequest) -> String {
        guard let data = bodyData(request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgs = obj["messages"] as? [[String: Any]] else { return "" }
        return msgs.compactMap { $0["content"] as? String }.joined(separator: "\n")
    }

    /// The `user` message content of a chat request body.
    static func userMessage(in request: URLRequest) -> String? {
        guard let data = bodyData(request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgs = obj["messages"] as? [[String: Any]],
              let last = msgs.last(where: { ($0["role"] as? String) == "user" }),
              let user = last["content"] as? String else { return nil }
        return user
    }

    static func jsonBody<Enc: Encodable>(_ value: Enc) -> Data {
        try! JSONEncoder().encode(value)
    }

    /// Reply body that mimics the OpenAI chat endpoint carrying `content`.
    static func chatReply(_ content: String) -> Data {
        let obj: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    static func modelsReply(_ ids: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0] }])
    }
}