// Tests of the storage server (`StorageServer`): the app's own `HttpStorage` against a real server
// on a loopback port, its key checks, and taking over a root the old Python server wrote.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk
@testable import PapertalkStore

/// A real `StorageServer` on 127.0.0.1 and a free port, over a temp folder.
final class StorageServerTests: PapertalkTestCase {
    private var root: URL!
    private var server: StorageServer!

    override func setUp() {
        super.setUp()
        root = Fixtures.tempDir()
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Start the server over `root` and return a client for it.
    private func start(token: String = "", clientToken: String? = nil) throws -> HttpStorage {
        server = try StorageServer(root: root, host: "127.0.0.1", port: 0, token: token)
        server.start()
        NetworkGuard.allowLocal(port: server.port)
        return HttpStorage(apiBase: "http://127.0.0.1:\(server.port)", token: clientToken ?? token)
    }

    /// A raw request to the server: its status and body.
    private func send(_ method: String, _ path: String, token: String? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as! HTTPURLResponse).statusCode, data)
    }

    func testTheAppsClientRoundTripsAPaper() async throws {
        let storage = try start()
        let paper = Fixtures.paper(id: "p1", title: "Waves")
        await storage.save(paper, K.paper("p1"))
        try await storage.write(K.turn("p1", 0), Data([1, 2, 3]))
        try await storage.write(K.libraries, Data("[]".utf8))

        let back = await storage.exists(Paper.self, K.paper("p1"))
        XCTAssertEqual(back?.title, "Waves")
        let turn = try await storage.read(K.turn("p1", 0))
        XCTAssertEqual(turn, Data([1, 2, 3]))
        let ids = try await storage.list()
        XCTAssertEqual(ids, ["p1"])
        // On disk it's the app's own library layout: one package per paper.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/p1.papertalk/turns/0.wav").path))

        try await storage.deleteFolder(K.folder("p1"))
        let keys = server.storage.allKeys()
        XCTAssertEqual(keys, [K.libraries])
        do {
            _ = try await storage.read(K.paper("p1"))
            XCTFail("a deleted key should be gone")
        } catch StorageError.status(let code) {
            XCTAssertEqual(code, 404)
        }
    }

    func testTheTokenIsRequired() async throws {
        let wrong = try start(token: "secret", clientToken: "nope")
        do {
            _ = try await wrong.list()
            XCTFail("a wrong token should be refused")
        } catch StorageError.status(let code) {
            XCTAssertEqual(code, 401)
        }
        let right = HttpStorage(apiBase: "http://127.0.0.1:\(server.port)", token: "secret")
        try await right.write("a.txt", Data("x".utf8))
        let data = try await right.read("a.txt")
        XCTAssertEqual(data, Data("x".utf8))
    }

    func testHeadListingAndRefusedKeys() async throws {
        let storage = try start()
        try await storage.write("papers/p/source.pdf", Data(count: 10))
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        let (headStatus, headBody) = try await send("HEAD", "/papers/p/source.pdf")
        XCTAssertEqual(headStatus, 200)
        XCTAssertTrue(headBody.isEmpty)
        let (missing, _) = try await send("HEAD", "/papers/p/nothing")
        XCTAssertEqual(missing, 404)

        let (listStatus, list) = try await send("GET", "/")
        XCTAssertEqual(listStatus, 200)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: list), ["papers/p/source.pdf"])   // no hidden files

        let (escape, _) = try await send("GET", "/%2E%2E/secret")
        XCTAssertEqual(escape, 400)
        let (folder, _) = try await send("DELETE", "/papers")
        XCTAssertEqual(folder, 200)
        XCTAssertEqual(server.storage.allKeys(), ["papers/p/source.pdf"])   // a folder isn't a key
        let (rootPut, _) = try await send("PUT", "/")
        XCTAssertEqual(rootPut, 400)
        let (other, _) = try await send("PATCH", "/a")
        XCTAssertEqual(other, 501)
    }

    func testAdoptsARootWrittenByThePythonServer() async throws {
        // storage_server.py stored papers in plain folders.
        let old = root.appendingPathComponent("papers/old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try JSONEncoder().encode(Fixtures.paper(id: "old")).write(to: old.appendingPathComponent("paper.json"))

        let storage = try start()
        let ids = try await storage.list()
        XCTAssertEqual(ids, ["old"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/old.papertalk/paper.json").path))
    }

    func testKeyRules() {
        for good in ["libraries.json", "papers/p/paper.json", "papers/p/turns/3.wav"] {
            XCTAssertTrue(StorageServer.isValidKey(good), good)
        }
        for bad in ["../x", "papers/../../etc/passwd", "/abs", "papers//x", "papers/.hidden", "a/", "a\0b"] {
            XCTAssertFalse(StorageServer.isValidKey(bad), bad)
        }
    }

    func testRequestHeadParsing() {
        let head = StorageServer.parseHead("PUT /papers/a%20b/paper.json?x=1 HTTP/1.1\r\nContent-Length: 3\r\nAuthorization: Bearer t")
        XCTAssertEqual(head?.method, "PUT")
        XCTAssertEqual(head?.path, "papers/a b/paper.json")
        XCTAssertEqual(head?.headers["content-length"], "3")
        XCTAssertEqual(head?.headers["authorization"], "Bearer t")
        XCTAssertNil(StorageServer.parseHead("GARBAGE"))
        XCTAssertNil(StorageServer.parseHead("GET / HTTP/1.1\r\nno colon here"))
        XCTAssertEqual(StorageServer.parseHead("GET // HTTP/1.1")?.path, "")
    }
}
