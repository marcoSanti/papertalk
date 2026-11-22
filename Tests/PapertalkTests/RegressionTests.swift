// Regression tests for data loss, crashes and leaks: an unreachable library written over, a
// library move, replies and files that crashed the app, Erase, and the storage server's gate.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import XCTest
@testable import Papertalk
@testable import PapertalkStore

private func library(_ id: String, _ name: String) -> Library {
    Library(id: id, name: name, icon: "folder", connectsAcross: false)
}

private func newLibrary(_ name: String) -> LibraryForm {
    var form = LibraryForm()
    form.name = name
    return form
}

private func suggestion(_ id: String) -> Suggestion {
    Suggestion(id: id, title: id, authors: [], source: .semanticScholar)
}

/// Long enough for a store's startup scan, or a write that mustn't happen, to have happened.
private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

/// A storage server behind `MockLLM` that can be unreachable, or answer with something else's page.
private final class FlakyServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var failure: (status: Int, body: Data)?
    private var writes = 0

    func fail(_ status: Int, _ body: String = "") { lock.withLock { failure = (status, Data(body.utf8)) } }
    func recover() { lock.withLock { failure = nil } }
    func put<T: Encodable>(_ value: T, _ key: String) { lock.withLock { files[key] = try? JSONEncoder().encode(value) } }
    func get<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        lock.withLock { files[key] }.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    var writeCount: Int { lock.withLock { writes } }

    func install() {
        MockLLM.install { [self] request in
            lock.withLock {
                let key = String((request.url?.path ?? "/").drop { $0 == "/" })
                if request.httpMethod == "PUT" { writes += 1 }
                if let failure { return failure }
                switch request.httpMethod {
                case "PUT": files[key] = MockLLM.bodyData(request) ?? Data(); return (200, Data())
                case "DELETE": files[key] = nil; return (200, Data())
                default:
                    if key.isEmpty { return (200, (try? JSONEncoder().encode(Array(files.keys))) ?? Data()) }
                    return files[key].map { (200, $0) } ?? (404, Data())
                }
            }
        }
    }

    var storage: HttpStorage { HttpStorage(apiBase: "http://mock.local:9170", token: "") }
}

/// A library that can't be read is never saved over.
@MainActor
final class UnreadableLibraryTests: TempLibraryTestCase {
    func testALibraryMadeAfterAnOfflineLaunchKeepsTheServersLibraries() async {
        let server = FlakyServer()
        server.put([library("L", "Mine")], K.libraries)
        server.put(Fixtures.paper(id: "p"), K.paper("p"))
        server.fail(503)
        server.install()
        let store = AppStore(storage: server.storage)
        await settle()

        server.recover()
        store.saveLibrary(newLibrary("Second"))
        await waitUntil { server.get([Library].self, K.libraries)?.map(\.name) == ["Mine", "Second"] }
        XCTAssertEqual(store.libraries.map(\.name), ["Mine", "Second"])
        XCTAssertNotNil(store.papers["p"], "the retry loads the papers too")
    }

    func testWhileTheServerIsDownNothingIsWrittenAndTheUserIsTold() async {
        let server = FlakyServer()
        server.fail(503)
        server.install()
        let store = AppStore(storage: server.storage)
        await settle()

        store.saveLibrary(newLibrary("Second"))
        await settle()
        XCTAssertEqual(server.writeCount, 0)
        XCTAssertTrue(store.libraries.isEmpty)
        XCTAssertNotNil(store.toast)
    }

    func testAnotherServersPageIsNotAnEmptyLibrary() async {
        let server = FlakyServer()
        server.put([library("L", "Mine")], K.libraries)
        server.fail(200, "<html>Sign in to the network</html>")
        server.install()
        let store = AppStore(storage: server.storage)
        await settle()

        store.saveLibrary(newLibrary("Second"))
        await settle()
        XCTAssertEqual(server.writeCount, 0)
    }

    func testAnUnreadSuggestionLogIsNotSavedOver() async {
        let server = FlakyServer()
        let log = SuggestionLog(pending: [suggestion("waiting")], handled: ["dismissed"])
        server.put(log, K.suggestions)
        server.fail(503)
        server.install()
        let store = AppStore(storage: server.storage)
        await settle()

        server.recover()
        store.dismissSuggestions(["other"])
        await settle()
        XCTAssertEqual(server.get(SuggestionLog.self, K.suggestions), log)
    }

    func testAnUndecodableLibrariesFileIsNotSavedOver() async throws {
        let damaged = Data("[{\"id\":".utf8)
        try await storage.write(K.libraries, damaged)
        let store = AppStore(storage: storage)
        await settle()

        store.saveLibrary(newLibrary("Second"))
        await settle()
        let kept = try await storage.read(K.libraries)
        XCTAssertEqual(kept, damaged)
    }

    func testADriveMountedAfterLaunchKeepsItsLibraries() async throws {
        let mount = dir.appendingPathComponent("drive")
        try Data().write(to: mount)   // not a folder: nothing can be read or made under it
        let away = LocalStorage(root: mount.appendingPathComponent("library"))
        let store = AppStore(storage: away)
        await settle()

        try FileManager.default.removeItem(at: mount)
        try await away.write(K.libraries, JSONEncoder().encode([library("L", "Mine")]))
        store.saveLibrary(newLibrary("Second"))
        await waitUntil { await away.exists([Library].self, K.libraries)?.map(\.name) == ["Mine", "Second"] }
    }

    func testSwitchingServerNeverCarriesLibrariesAcross() async {
        let saved = UserDefaults.standard.object(forKey: ServerConfig.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: ServerConfig.defaultsKey) }
        let server = FlakyServer()
        server.put([library("A", "On the first")], K.libraries)
        server.install()
        let store = AppStore(storage: server.storage)
        await waitUntil { store.libraries.map(\.id) == ["A"] }

        server.put([library("B", "On the second")], K.libraries)   // what the other server holds
        store.saveServerSettings(ServerConfig(apiBase: "http://other.test:9170", token: ""))
        await settle()
        store.saveLibrary(newLibrary("New"))
        await waitUntil { server.get([Library].self, K.libraries)?.map(\.name) == ["On the second", "New"] }
    }
}

/// Moving the library folder takes the whole library.
@MainActor
final class LibraryMoveTests: TempLibraryTestCase {
    private var other: URL { dir.appendingPathComponent("other", isDirectory: true) }

    func testLibrariesAndSuggestionsMoveWithThePapers() async throws {
        await storage.save([library("L", "Mine")], K.libraries)
        let log = SuggestionLog(pending: [suggestion("waiting")], handled: ["dismissed"])
        await storage.save(log, K.suggestions)
        await storage.save(Fixtures.paper(id: "p"), K.paper("p"))

        try LocalStorage.moveLibrary(from: dir, to: other)
        let there = LocalStorage(root: other)
        let libraries = await there.exists([Library].self, K.libraries)
        let suggestions = await there.exists(SuggestionLog.self, K.suggestions)
        XCTAssertEqual(libraries, [library("L", "Mine")])
        XCTAssertEqual(suggestions, log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(K.libraries).path))
    }

    func testAFolderWithALibraryKeepsItsOwnAndGainsTheMovedOne() async throws {
        await storage.save([library("L", "Mine"), library("S", "Old name")], K.libraries)
        await storage.save(SuggestionLog(pending: [suggestion("a"), suggestion("b")], handled: ["x"]), K.suggestions)
        let there = LocalStorage(root: other)
        await there.save([library("T", "Theirs"), library("S", "Kept name")], K.libraries)
        await there.save(SuggestionLog(pending: [suggestion("b"), suggestion("x")], handled: ["y"]), K.suggestions)

        try LocalStorage.moveLibrary(from: dir, to: other)
        let libraries = await there.exists([Library].self, K.libraries)
        let log = await there.exists(SuggestionLog.self, K.suggestions)
        XCTAssertEqual(libraries?.map(\.name), ["Theirs", "Kept name", "Mine"])
        XCTAssertEqual(log?.pending.map(\.id), ["b", "a"], "x was dismissed in one of them")
        XCTAssertEqual(log?.handled, ["y", "x"])
    }

    func testAnUnreadableDestinationStopsTheMoveBeforeAnythingMoves() async throws {
        await storage.save([library("L", "Mine")], K.libraries)
        await storage.save(Fixtures.paper(id: "p"), K.paper("p"))
        try await LocalStorage(root: other).write(K.libraries, Data("damaged".utf8))

        XCTAssertThrowsError(try LocalStorage.moveLibrary(from: dir, to: other))
        let paper = await storage.exists(Paper.self, K.paper("p"))
        let libraries = await storage.exists([Library].self, K.libraries)
        XCTAssertNotNil(paper)
        XCTAssertEqual(libraries, [library("L", "Mine")])
    }

    func testTheSameFolderUnderAnotherNameLosesNothing() async throws {
        await storage.save([library("L", "Mine")], K.libraries)
        let alias = Fixtures.tempDir().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: alias.deletingLastPathComponent()) }

        try LocalStorage.moveLibrary(from: dir, to: alias)
        let libraries = await storage.exists([Library].self, K.libraries)
        XCTAssertEqual(libraries, [library("L", "Mine")])
    }
}

/// LLM replies that used to crash the app.
final class HostileReplyTests: PapertalkTestCase {
    private func segments(_ list: String) async throws -> [Transcript.Segment] {
        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            if text.contains(#""segments": [{"title""#) {
                return (200, MockLLM.chatReply(#"{"sections":[{"title":"Method"}],"segments":[\#(list)]}"#))
            }
            return (200, MockLLM.chatReply("Jordan: Hello there.\nSam: Hello to you."))
        }
        return try await LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "", model: "m")
            .generateTranscript(text: "T\nMethod\nWe measure.", depth: .inDepth, expert: "Sam").transcript.segments
    }

    func testAClosingBraceBeforeTheOpeningOneIsNoJSON() {
        XCTAssertNil(LLMReply.json("cut off } then {"))
        XCTAssertNil(LLMReply.object("}{"))
        XCTAssertEqual(LLMReply.json("} sorry: {\"a\":1}"), "{\"a\":1}")
    }

    func testWeightsThatAreAllZeroSplitTheEpisodeEvenly() async throws {
        let written = try await segments(#"{"title":"A","weight":0},{"title":"B","weight":0}"#)
        XCTAssertEqual(written.count, 2)
    }

    func testNegativeAndOverflowingWeights() async throws {
        for list in [#"{"title":"A","weight":-1},{"title":"B","weight":1}"#, #"{"title":"A","weight":"inf"}"#,
                     #"{"title":"A","weight":"nan"}"#, #"{"title":"A","weight":1e308},{"title":"B","weight":1e308}"#] {
            let written = try await segments(list)
            XCTAssertFalse(written.isEmpty, list)
        }
    }

    func testSectionNumbersOutsideTheIndexAreIgnored() async throws {
        for number in ["0", "-3", "99", "-9223372036854775808"] {
            let written = try await segments(#"{"title":"M","weight":1,"monologue":true,"sections":[\#(number)]}"#)
            XCTAssertEqual(written.count, 1, number)
        }
    }

    func testRankingNumbersOutsideTheListAreIgnored() {
        let reply = #"{"ranked":[{"n":-9223372036854775808},{"n":0},{"n":1}]}"#
        XCTAssertEqual(Suggestions.applyRanking(reply, to: [suggestion("a")])?.map(\.id), ["a"])
    }
}

/// A typed URL that isn't one is an error, not a crash.
final class InvalidURLTests: PapertalkTestCase {
    private let invalid = ["http://[bad", "/", "not a url", "localhost"]

    func testStorageServerURL() async {
        for url in invalid {
            do {
                _ = try await HttpStorage(apiBase: url, token: "").list()
                XCTFail("\(url) was used")
            } catch {
                XCTAssertTrue(error is StorageError, "\(url): \(error)")
            }
        }
    }

    func testLLMURLForTheModelList() async {
        for url in invalid {
            do {
                _ = try await LocalPipeline(baseUrl: url, apiKey: "", model: "m").listModels()
                XCTFail("\(url) was used")
            } catch {
                XCTAssertTrue(error is PipelineError, "\(url): \(error)")
            }
        }
    }

    func testLLMURLForAChat() async {
        for url in invalid {
            do {
                _ = try await LocalPipeline(baseUrl: url, apiKey: "", model: "m").chat(messages: [], maxTokens: 1)
                XCTFail("\(url) was used")
            } catch {
                XCTAssertTrue(error is PipelineError, "\(url): \(error)")
            }
        }
    }
}

/// Mind maps in files made to crash the app.
@MainActor
final class HostileMapTests: TempLibraryTestCase {
    private func node(_ id: String, parent: String? = nil) -> MindMap.Node {
        MindMap.Node(id: id, label: id, branch: .problem, parent: parent, description: "", core: "")
    }

    func testABundleWithDuplicateConceptIdsImportsWithoutItsMap() async throws {
        let id = UUID().uuidString
        let bundle = dir.appendingPathComponent("crafted.papertalk", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try JSONEncoder().encode(Fixtures.paper(id: id)).write(to: bundle.appendingPathComponent("paper.json"))
        try JSONEncoder().encode(Fixtures.transcript([("A", "Hello")])).write(to: bundle.appendingPathComponent("transcript.json"))
        try JSONEncoder().encode(MindMap(nodes: [node("a"), node("a", parent: "a")], links: []))
            .write(to: bundle.appendingPathComponent("mindmap.json"))

        let library = LocalStorage(root: dir.appendingPathComponent("library"))
        let store = AppStore(storage: library)
        await settle()
        let imported = await store.importPaper(from: bundle)
        XCTAssertEqual(imported, id)
        let map = await store.mindMap(for: id)
        if let map { _ = MindMapLayout(map) }   // what crashed
        XCTAssertNil(map)
        XCTAssertEqual(store.papers[id]?.hasMindMap, false)
    }

    func testMapsTooDeepOrTooBigToDrawDoNotDecode() async throws {
        let chain = (0..<400).map { node("n\($0)", parent: $0 == 0 ? nil : "n\($0 - 1)") }
        let wide = [node("root")] + (0..<3000).map { node("n\($0)", parent: "root") }
        for nodes in [chain, wide] {
            let data = try JSONEncoder().encode(MindMap(nodes: nodes, links: []))
            XCTAssertThrowsError(try JSONDecoder().decode(MindMap.self, from: data))
        }
    }

    func testAnOrdinaryMapStillDecodes() async throws {
        let map = MindMap(nodes: [node("a"), node("b", parent: "a"), node("c", parent: "b")], links: [], summary: "S")
        XCTAssertEqual(try JSONDecoder().decode(MindMap.self, from: JSONEncoder().encode(map)), map)
    }
}

/// Erase library and settings leaves no account behind.
@MainActor
final class EraseTests: TempLibraryTestCase {
    /// Every default Erase writes, put back after each test.
    nonisolated private static let keys = [ServerConfig.defaultsKey, LLMSettings.defaultsKey, SpeechSettings.defaultsKey,
        PromptSettings.defaultsKey, CustomDepthPresets.defaultsKey, MailSettings.defaultsKey, ImportChoice.defaultsKey,
        LocalStorage.folderDefaultsKey, Localization.defaultsKey, AppStore.askDeleteKey, AppStore.checkUpdatesKey,
        PlayerController.speedKey, "papertalk.onboarded", "papertalk.suggestions.enabled", "papertalk.settingsPage"]
    nonisolated(unsafe) private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in Self.keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    func testEraseRemovesTheMailAccountPasswordAndSuggestions() async {
        await storage.save(SuggestionLog(pending: [suggestion("waiting")], readAlerts: ["me@example.com|INBOX|1"]), K.suggestions)
        await storage.save(Fixtures.paper(id: "p"), K.paper("p"))
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == 1 && store.suggestionLog.pending.count == 1 }
        var password = "app-password"
        store.mailPassword = { password }
        store.storeMailPassword = { password = $0 }
        store.mail = MailSettings(enabled: true, account: "me@example.com")
        store.suggestionsEnabled = true
        store.importChoice = ImportChoice(depth: "custom", depthNote: "my notes")
        store.showOnboarding = false

        store.clearAll()
        await waitUntil(timeout: 5) { store.showOnboarding }
        XCTAssertEqual(password, "")
        XCTAssertEqual(store.mail, MailSettings())
        XCTAssertEqual(MailSettings.load(), MailSettings())
        XCTAssertEqual(ImportChoice.load(), ImportChoice())
        XCTAssertFalse(store.suggestionsEnabled)
        XCTAssertEqual(store.suggestionLog, SuggestionLog())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(K.suggestions).path))
    }

    func testACheckUnderWayDoesNotBringErasedSuggestionsBack() async {
        await storage.save(Fixtures.paper(id: "p", doi: "10.1/p"), K.paper("p"))
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == 1 }
        store.mailPassword = { "" }
        store.storeMailPassword = { _ in }
        store.showOnboarding = false
        MockLLM.install { _ in
            Thread.sleep(forTimeInterval: 0.6)   // Erase lands while the check waits for this
            return (200, Data(#"{"recommendedPapers":[{"title":"Late arrival"}]}"#.utf8))
        }

        let check = Task { await store.checkSuggestions() }
        await waitUntil { store.isCheckingSuggestions }
        try? await Task.sleep(nanoseconds: 150_000_000)
        store.clearAll()
        await check.value
        await waitUntil(timeout: 5) { store.showOnboarding }
        await settle()
        XCTAssertEqual(store.suggestionLog, SuggestionLog())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(K.suggestions).path))
    }
}

/// The storage server turns strangers away before reading what they send.
final class StorageServerGateTests: StorageServerTestCase {
    private func start(token: String) throws {
        server = try StorageServer(root: root, host: "127.0.0.1", port: 0, token: token)
        server.start()
    }

    /// The first line answered to `head`, sent without the body it announces; "" when none comes.
    private func answer(to head: String) -> String {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(server.port)).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return "" }
        let request = Array((head + "\r\n\r\n").utf8)
        guard send(fd, request, request.count, 0) == request.count else { return "" }
        var bytes = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &bytes, bytes.count, 0)
        return n > 0 ? String(String(decoding: bytes[..<n], as: UTF8.self).prefix { $0 != "\r\n" }) : ""
    }

    func testTheTokenIsCheckedBeforeTheBodyIsRead() throws {
        try start(token: "secret")
        for auth in ["", "\r\nAuthorization: Bearer nope"] {
            XCTAssertEqual(answer(to: "PUT /a.bin HTTP/1.1\r\nContent-Length: 10000000\(auth)"), "HTTP/1.1 401 Unauthorized")
        }
    }

    func testATooLargeUploadIsRefusedBeforeItIsRead() throws {
        try start(token: "secret")
        XCTAssertEqual(answer(to: "PUT /a.bin HTTP/1.1\r\nContent-Length: 900000000000\r\nAuthorization: Bearer secret"),
                       "HTTP/1.1 413 Content Too Large")
    }

    func testAFileThatCannotBeReadIsNotReportedMissing() throws {
        try XCTSkipIf(getuid() == 0, "root reads everything")
        try start(token: "")
        let file = root.appendingPathComponent("libraries.json")
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertEqual(answer(to: "GET /libraries.json HTTP/1.1"), "HTTP/1.1 500 Internal Server Error")
        XCTAssertEqual(answer(to: "GET /nothing.json HTTP/1.1"), "HTTP/1.1 404 Not Found")
    }

    /// The addresses this process listens on at the server's port.
    private var boundAddresses: [UInt32] {
        (3..<Int32(1024)).compactMap { fd -> UInt32? in
            var addr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard found == 0, Int32(addr.sin_family) == AF_INET, Int(UInt16(bigEndian: addr.sin_port)) == server.port else { return nil }
            return UInt32(bigEndian: addr.sin_addr.s_addr)
        }
    }

    func testWithoutATokenItListensOnThisMachineOnly() throws {
        server = try StorageServer(root: root, port: 0)
        server.start()
        XCTAssertEqual(boundAddresses, [0x7F00_0001])
    }

    func testWithATokenItStillListensOnTheNetwork() throws {
        server = try StorageServer(root: root, port: 0, token: "secret")
        server.start()
        XCTAssertEqual(boundAddresses, [0])
    }
}

/// A library on disk whose chosen keys, or whose listing, can't be read.
private final class UnreliableStorage: Storage, @unchecked Sendable {
    private let disk: LocalStorage
    private let lock = NSLock()
    private var broken: Set<String> = []
    private var listFails = false
    private var asked: [String] = []

    init(_ disk: LocalStorage) { self.disk = disk }
    func fail(_ key: String) { lock.withLock { _ = broken.insert(key) } }
    func failListing() { lock.withLock { listFails = true } }
    var keysRead: [String] { lock.withLock { asked } }

    private func check(_ key: String) throws {
        let fails = lock.withLock { () -> Bool in
            asked.append(key)
            return broken.contains(key)
        }
        if fails { throw URLError(.timedOut) }
    }
    func read(_ key: String) async throws -> Data { try check(key); return try await disk.read(key) }
    func readIfPresent(_ key: String) async throws -> Data? { try check(key); return try await disk.readIfPresent(key) }
    func write(_ key: String, _ data: Data) async throws { try await disk.write(key, data) }
    func delete(_ key: String) async throws { try await disk.delete(key) }
    func deleteFolder(_ prefix: String) async throws { try await disk.deleteFolder(prefix) }
    func list() async throws -> [String] {
        if lock.withLock({ listFails }) { throw URLError(.timedOut) }
        return try await disk.list()
    }
    func url(for key: String) async -> URL? { await disk.url(for: key) }
}

/// Saving a mind map never drops a connection it couldn't check.
@MainActor
final class MindMapSaveTests: TempLibraryTestCase {
    private func link(_ from: String, to paper: String, _ node: String) -> MindMap.ExternalLink {
        MindMap.ExternalLink(from: from, paperId: paper, paperTitle: paper, nodeId: node, nodeLabel: node, label: "same")
    }

    private func map(_ node: String, links: [MindMap.ExternalLink]) -> MindMap {
        MindMap(nodes: [MindMap.Node(id: node, label: node, branch: .problem, parent: nil, description: "", core: "")],
                links: [], external: links)
    }

    /// "p" and "q", connected both ways, behind storage that can be made to fail.
    private func connectedPapers() async -> UnreliableStorage {
        await Fixtures.saveMappedPaper(id: "p", title: "P", map: map("a", links: [link("a", to: "q", "b")]), in: storage)
        await Fixtures.saveMappedPaper(id: "q", title: "Q", map: map("b", links: [link("b", to: "p", "a")]), in: storage)
        return UnreliableStorage(storage)
    }

    private func saved(_ id: String) async -> MindMap? { await storage.exists(MindMap.self, K.mindMap(id)) }

    func testAnEditKeepsConnectionsToAMapThatCantBeRead() async throws {
        let flaky = await connectedPapers()
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 2 }
        let shown = await store.mindMap(for: "p")
        var edited = try XCTUnwrap(shown)
        edited.summary = "Edited"
        flaky.fail(K.mindMap("q"))

        store.saveMindMap("p", edited)
        await waitUntil { await self.saved("p")?.summary == "Edited" }
        let mine = await saved("p"), theirs = await saved("q")
        XCTAssertEqual(mine?.externalLinks, [link("a", to: "q", "b")])
        XCTAssertEqual(theirs?.externalLinks, [link("b", to: "p", "a")])
    }

    func testRemovingAConnectionWaitsUntilBothSidesCanBeWritten() async throws {
        let flaky = await connectedPapers()
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 2 }
        let shown = await store.mindMap(for: "p")
        var edited = try XCTUnwrap(shown)
        edited.deleteExternal(from: "a", paperId: "q", nodeId: "b")
        flaky.fail(K.mindMap("q"))

        store.saveMindMap("p", edited)
        await settle()
        let mine = await saved("p")
        XCTAssertEqual(mine?.externalLinks, [link("a", to: "q", "b")], "removed on one side only otherwise")
        XCTAssertNotNil(store.toast)
    }

    func testAnEditKeepsConnectionsToAPaperThatDidntLoad() async throws {
        let flaky = await connectedPapers()
        flaky.fail(K.paper("q"))
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 1 }
        let shown = await store.mindMap(for: "p")   // "q" is unknown, so its connection is hidden
        var edited = try XCTUnwrap(shown)
        edited.summary = "Edited"

        store.saveMindMap("p", edited)
        await waitUntil { await self.saved("p")?.summary == "Edited" }
        let mine = await saved("p")
        XCTAssertEqual(mine?.externalLinks, [link("a", to: "q", "b")])
    }

    func testAnEditKeepsHiddenConnectionsWhileTheLibraryCantBeListed() async throws {
        let flaky = await connectedPapers()
        flaky.fail(K.paper("q"))
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 1 }
        let shown = await store.mindMap(for: "p")
        var edited = try XCTUnwrap(shown)
        edited.summary = "Edited"
        flaky.failListing()

        store.saveMindMap("p", edited)
        await waitUntil { await self.saved("p")?.summary == "Edited" }
        let mine = await saved("p")
        XCTAssertEqual(mine?.externalLinks, [link("a", to: "q", "b")])
    }

    func testAMapWhoseSavedCopyCantBeReadIsNotSavedOver() async throws {
        let flaky = await connectedPapers()
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 2 }
        let before = await saved("p")
        flaky.fail(K.mindMap("p"))

        store.saveMindMap("p", map("a", links: []))
        await settle()
        let after = await saved("p")
        XCTAssertEqual(after, before)
        XCTAssertNotNil(store.toast)
    }

    func testConnectionsToPapersThatAreGoneStillGoAndTheirIdsAreNeverPaths() async throws {
        let stray = map("a", links: [link("a", to: "deleted", "x"), link("a", to: "../../outside", "y")])
        await Fixtures.saveMappedPaper(id: "p", title: "P", map: stray, in: storage)
        let flaky = UnreliableStorage(storage)
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 1 }

        store.saveMindMap("p", stray)
        await waitUntil { await self.saved("p")?.externalLinks.isEmpty == true }
        XCTAssertFalse(flaky.keysRead.contains { $0.contains("..") })
    }

    func testRemovingAReadableConnectionStillRemovesBothSides() async throws {
        let flaky = await connectedPapers()
        let store = AppStore(storage: flaky)
        await waitUntil { store.papers.count == 2 }

        store.saveMindMap("p", map("a", links: []))
        await waitUntil {
            let mine = await self.saved("p"), theirs = await self.saved("q")
            return mine?.externalLinks.isEmpty == true && theirs?.externalLinks.isEmpty == true
        }
    }
}
