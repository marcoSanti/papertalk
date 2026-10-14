import XCTest
@testable import Papertalk

/// LocalStorage round-trips against a throwaway temp folder, so tests never
/// touch the user's real library in Application Support.
final class LocalStorageTests: PapertalkTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var store: LocalStorage { LocalStorage(root: dir) }

    func testWriteRead() async throws {
        let s = store
        let data = Data("hello".utf8)
        try await s.write("a/b.txt", data)
        let back = try await s.read("a/b.txt")
        XCTAssertEqual(String(decoding: back, as: UTF8.self), "hello")
    }

    func testListOnlyPapersWithJSON() async throws {
        let s = store
        let paper = Paper(id: "1", title: "T", filename: nil, hasPdf: true, hasScript: false, hasAudio: false,
                          createdIso: nil, publishedIso: nil, state: "draft", tags: [], favorite: false,
                          authors: [], affiliations: [], doi: "", read: false, depth: nil, bibtex: nil,
                          progress: 0, duration: 0, progressTs: nil, stage: nil, message: nil, statusError: nil)
        await s.save(paper, K.paper("1"))
        try await s.write(K.transcript("1"), Data("x".utf8)) // an artifact but not paper.json
        try await s.write("papers/2/stray.txt", Data("orphan".utf8)) // no paper.json
        let ids = try await s.list()
        XCTAssertEqual(ids, ["1"])
    }

    func testDeleteItem() async throws {
        let s = store
        try await s.write(K.transcript("7"), Data("x".utf8))
        let before = try? await s.read(K.transcript("7"))
        XCTAssertNotNil(before)
        try await s.delete(K.transcript("7"))
        let after = try? await s.read(K.transcript("7"))
        XCTAssertNil(after)
    }

    func testDeleteFolderRemovesSubfolder() async throws {
        let s = store
        for i in 0..<3 {
            try await s.write(K.turn("9", i), Data("x".utf8))
        }
        try await s.deleteFolder(K.folder("9"))
        let keys = try await s.list()
        XCTAssertTrue(keys.isEmpty)
    }

    func testSaveExistsDecode() async throws {
        let s = store
        let transcript = Transcript(paperTitle: "P", speakers: [.init(name: "A")], segments: [])
        await s.save(transcript, K.transcript("5"))
        let back: Transcript? = await s.exists(Transcript.self, K.transcript("5"))
        XCTAssertEqual(back?.paperTitle, "P")
        let missing: Transcript? = await s.exists(Transcript.self, K.transcript("nope"))
        XCTAssertNil(missing)
    }

    func testURLIsLocalFilePath() async throws {
        let s = store
        let url = await s.url(for: K.paper("1"))
        XCTAssertTrue(url?.isFileURL ?? false)
    }
}

final class HttpStorageTests: PapertalkTestCase {
    func testFolderAndListParsing() async throws {
        // Cover the pure URL/key derivations in HttpStorage without a server.
        let s = HttpStorage(apiBase: "http://host:9170/", token: "")
        let url = await s.url(for: K.paper("abc"))
        XCTAssertEqual(url?.absoluteString, "http://host:9170/papers/abc/paper.json")
        let noTrailing = HttpStorage(apiBase: "http://host:9170", token: "tok")
        let url2 = await noTrailing.url(for: "k")
        XCTAssertEqual(url2?.absoluteString, "http://host:9170/k")
    }
}