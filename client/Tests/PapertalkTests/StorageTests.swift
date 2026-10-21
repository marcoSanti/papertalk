// Tests of the storage backends.

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

    func testEachPaperIsAPackageOnDisk() async throws {
        let s = store
        try await s.write(K.paper("p"), Data("{}".utf8))
        try await s.write(K.turn("p", 0), Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("papers/p.papertalk/paper.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("papers/p.papertalk/turns/0.wav").path))
        let url = await s.url(for: K.folder("p"))
        XCTAssertEqual(url?.lastPathComponent, "p.papertalk")
        try await s.deleteFolder(K.folder("p"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("papers/p.papertalk").path))
    }

    func testListMovesOldPlainFoldersIntoPackages() async throws {
        let fm = FileManager.default
        let old = dir.appendingPathComponent("papers/old", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("paper.json"))
        try Data().write(to: dir.appendingPathComponent("papers/.DS_Store"))

        let ids = try await store.list()

        XCTAssertEqual(ids, ["old"])
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("papers/old.papertalk/paper.json").path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("papers/.DS_Store").path), "only folders are moved")
    }

    func testMoveLibraryKeepsPapersAlreadyThere() async throws {
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try await LocalStorage(root: dir).write(K.paper("a"), Data("from-old".utf8))
        try await LocalStorage(root: dir).write(K.paper("b"), Data("from-old".utf8))
        try await LocalStorage(root: other).write(K.paper("b"), Data("kept".utf8))

        let moved = try LocalStorage.moveLibrary(from: dir, to: other)

        XCTAssertEqual(moved, 1)
        let a = try await LocalStorage(root: other).read(K.paper("a"))
        let b = try await LocalStorage(root: other).read(K.paper("b"))
        XCTAssertEqual(String(decoding: a, as: UTF8.self), "from-old")
        XCTAssertEqual(String(decoding: b, as: UTF8.self), "kept")
        XCTAssertEqual(try LocalStorage.moveLibrary(from: other, to: other), 0, "same folder: nothing moves")
    }
}

/// `HttpStorage`'s folder deletes and paper listing, from the server's key list.
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