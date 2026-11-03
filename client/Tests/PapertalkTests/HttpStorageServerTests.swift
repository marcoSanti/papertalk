// Tests of `HttpStorage` against a fake storage server.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk

/// `HttpStorage` against an in-process fake of the storage server (`StorageServerTests` uses the real one)
/// (a flat key -> bytes map behind GET / PUT / DELETE).
final class HttpStorageServerTests: PapertalkTestCase {
    /// The fake server's contents and the requests it received.
    private final class FakeServer: @unchecked Sendable {
        var files: [String: Data] = [:]
        var requests: [(method: String, key: String, auth: String?)] = []
        var failWith: Int?

        func handle(_ request: URLRequest) -> (status: Int, body: Data) {
            let key = String((request.url?.path ?? "/").dropFirst())
            let method = request.httpMethod ?? "GET"
            requests.append((method, key, request.value(forHTTPHeaderField: "Authorization")))
            if let failWith { return (failWith, Data()) }
            switch method {
            case "GET" where key.isEmpty:
                return (200, try! JSONSerialization.data(withJSONObject: Array(files.keys)))
            case "GET":
                return files[key].map { (200, $0) } ?? (404, Data())
            case "PUT":
                files[key] = MockLLM.bodyData(request) ?? Data()
                return (200, Data())
            case "DELETE":
                return files.removeValue(forKey: key) != nil ? (200, Data()) : (404, Data())
            default:
                return (405, Data())
            }
        }
    }

    private var server: FakeServer!

    override func setUp() {
        super.setUp()
        server = FakeServer()
        let s = server!
        MockLLM.install { s.handle($0) }
    }

    private func storage(token: String = "") -> HttpStorage {
        HttpStorage(apiBase: "http://mock.local:9170", token: token)
    }

    func testWriteThenReadRoundTrips() async throws {
        let s = storage()
        try await s.write(K.pdf("a"), Data("pdf-bytes".utf8))
        let data = try await s.read(K.pdf("a"))
        XCTAssertEqual(data, Data("pdf-bytes".utf8))
        XCTAssertEqual(server.files.keys.sorted(), ["papers/a/source.pdf"])
    }

    func testReadMissingKeyThrows() async {
        do {
            _ = try await storage().read("papers/nope/paper.json")
            XCTFail("expected a 404 to throw")
        } catch {
            XCTAssertEqual((error as? StorageError).map { "\($0)" }, "\(StorageError.status(404))")
        }
    }

    func testListReturnsOnlyPaperIdsWithARecord() async throws {
        server.files = [
            "papers/a/paper.json": Data(), "papers/a/source.pdf": Data(),
            "papers/b/paper.json": Data(),
            "papers/orphan/turns/0.wav": Data(),          // no record: not a paper
            "other/thing": Data(),
        ]
        let ids = try await storage().list()
        XCTAssertEqual(ids.sorted(), ["a", "b"])
    }

    func testDeleteFolderRemovesOnlyThatPapersKeys() async throws {
        server.files = [
            "papers/a/paper.json": Data(), "papers/a/turns/0.wav": Data(), "papers/a/extra.bin": Data(),
            "papers/ab/paper.json": Data(),               // shares a prefix with "a" but not the folder
        ]
        try await storage().deleteFolder(K.folder("a"))
        XCTAssertEqual(server.files.keys.sorted(), ["papers/ab/paper.json"])
    }

    func testExistsDecodesOrReturnsNil() async throws {
        let s = storage()
        await s.save(Fixtures.paper(id: "a", title: "Remote"), K.paper("a"))
        let found = await s.exists(Paper.self, K.paper("a"))
        XCTAssertEqual(found?.title, "Remote")
        let missing = await s.exists(Paper.self, K.paper("zzz"))
        XCTAssertNil(missing)
    }

    func testTokenIsSentAsBearerOnlyWhenSet() async throws {
        try await storage(token: "secret").write("k", Data())
        try await storage().write("k2", Data())
        XCTAssertEqual(server.requests.map(\.auth), ["Bearer secret", nil])
    }

    func testServerErrorsSurface() async {
        server.failWith = 500
        do {
            try await storage().write("k", Data())
            XCTFail("expected a 500 to throw")
        } catch {
            XCTAssertNotNil(error as? StorageError)
        }
    }
}
