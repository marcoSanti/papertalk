import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk

/// Records what it was asked to say and answers with silence, so synthesis
/// paths can be followed without Kokoro or a server.
final class FakeSpeechBackend: SpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(text: String, voice: String)] = []
    private var inFlight = 0, _mostInFlight = 0
    var calls: [(text: String, voice: String)] { lock.withLock { _calls } }
    /// The most calls that were running at the same moment.
    var mostInFlight: Int { lock.withLock { _mostInFlight } }
    let seconds: Double
    let parallelRequests: Int
    let delay: UInt64
    /// Text that makes a call fail, to follow error handling.
    let failOn: String?
    init(seconds: Double = 0.5, parallel: Int = 1, delayMs: UInt64 = 0, failOn: String? = nil) {
        self.seconds = seconds
        parallelRequests = parallel
        delay = delayMs * 1_000_000
        self.failOn = failOn
    }

    var preparingMessage: String { "Fake preparing" }
    var preparationShare: Double { 0 }
    var loadsModel: Bool { false }
    var maxPieceLength: Int { 40 }
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        lock.withLock { _calls.append((text, voice)); inFlight += 1; _mostInFlight = max(_mostInFlight, inFlight) }
        defer { lock.withLock { inFlight -= 1 } }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if text == failOn { throw RemoteSpeechError.http(500, "boom") }
        return Fixtures.silentWAV(seconds: seconds)
    }
}

/// Values collected from concurrent mock requests.
final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

/// A WAV in any layout, for the normalizer.
private func wav(rate: Int, channels: Int, bits: Int, float: Bool = false, frames: Int,
                 extraChunk: Bool = false, streamedSize: Bool = false, value: Double = 0.25) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = frames * channels * bits / 8
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(float ? 3 : 1); u16(UInt16(channels))
    u32(UInt32(rate)); u32(UInt32(rate * channels * bits / 8)); u16(UInt16(channels * bits / 8)); u16(UInt16(bits))
    if extraChunk { d.append(contentsOf: Array("LIST".utf8)); u32(3); d.append(contentsOf: [1, 2, 3, 0]) }
    d.append(contentsOf: Array("data".utf8)); u32(streamedSize ? 0xFFFF_FFFF : UInt32(bytes))
    for _ in 0..<(frames * channels) {
        switch (float, bits) {
        case (true, _): u32(Float(value).bitPattern)
        case (_, 16): u16(UInt16(bitPattern: Int16(value * 32767)))
        case (_, 24):
            let v = Int32(value * 8_388_607)
            d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)])
        default: d.append(UInt8(128 + Int(value * 127)))
        }
    }
    return d
}

private func body(_ request: URLRequest) -> [String: Any] {
    (MockLLM.bodyData(request).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

private let remote = SpeechSettings(engine: .remote, baseUrl: "http://tts.test/api/v1/", apiKey: "sk-tts", model: "kokoro")

final class SpeechAudioTests: PapertalkTestCase {
    func testCanonicalWAVIsKeptAsIs() throws {
        let canonical = Fixtures.silentWAV(seconds: 0.2)
        XCTAssertEqual(try SpeechAudio.normalizedWAV(canonical), canonical)
    }

    func testOtherLayoutsBecomeTheAppsLayout() throws {
        let cases: [(String, Data)] = [
            ("48 kHz stereo", wav(rate: 48_000, channels: 2, bits: 16, frames: 48_000)),
            ("float", wav(rate: 24_000, channels: 1, bits: 32, float: true, frames: 24_000)),
            ("24-bit 22 kHz", wav(rate: 22_050, channels: 1, bits: 24, frames: 22_050)),
            ("8-bit", wav(rate: 16_000, channels: 1, bits: 8, frames: 16_000)),
            ("extra chunk", wav(rate: 24_000, channels: 1, bits: 16, frames: 24_000, extraChunk: true)),
            ("streamed size", wav(rate: 24_000, channels: 1, bits: 16, frames: 24_000, streamedSize: true)),
        ]
        for (name, input) in cases {
            let out = try SpeechAudio.normalizedWAV(input)
            let parsed = try SpeechAudio.parseWAV(out)
            XCTAssertTrue(parsed.isCanonical, name)
            XCTAssertEqual(KokoroSpeech.wavDuration(out), 1.0, accuracy: 0.01, name)
            // The level survives the conversion (about a quarter of full scale).
            XCTAssertEqual(parsed.mono[1000], 0.25, accuracy: 0.02, name)
        }
    }

    func testUnreadableAudioIsAPlainError() {
        XCTAssertThrowsError(try SpeechAudio.normalizedWAV(Data())) { XCTAssertEqual($0 as? SpeechAudio.Failure, .empty) }
        var broken = wav(rate: 24_000, channels: 1, bits: 16, frames: 10)
        broken.replaceSubrange(20..<22, with: [7, 0])   // an unknown sample format
        XCTAssertThrowsError(try SpeechAudio.normalizedWAV(broken)) { XCTAssertEqual($0 as? SpeechAudio.Failure, .unreadable) }
        XCTAssertThrowsError(try SpeechAudio.normalizedWAV(Data("not audio at all".utf8)))
    }

    func testJoinedPiecesStayReadable() throws {
        let joined = KokoroSpeech.joinWAVs([Fixtures.silentWAV(seconds: 0.5), Fixtures.silentWAV(seconds: 0.25)])
        XCTAssertTrue(try SpeechAudio.parseWAV(joined).isCanonical)
        XCTAssertEqual(KokoroSpeech.wavDuration(joined), 0.75, accuracy: 0.001)
    }
}

final class SpeechSettingsTests: PapertalkTestCase {
    func testDecodingIsTolerant() throws {
        let empty = try JSONDecoder().decode(SpeechSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, SpeechSettings())
        // Settings saved by an earlier build (role voices) or a later one (unknown engine).
        let future = try JSONDecoder().decode(SpeechSettings.self, from: Data(#"{"engine":"cloud","baseUrl":"http://x","voices":{"hostMale":"onyx"},"parallelRequests":99}"#.utf8))
        XCTAssertEqual(future.engine, .local)
        XCTAssertEqual(future.baseUrl, "http://x")
        XCTAssertEqual(future.parallelRequests, SpeechSettings.parallelRange.upperBound)
        XCTAssertEqual(empty.parallelRequests, SpeechSettings.defaultParallelRequests)
        XCTAssertEqual(SpeechSettings(parallelRequests: 0).parallelRequests, 1)
        XCTAssertEqual(future.keyEnv, "")
    }

    func testResolvedKey() {
        XCTAssertEqual(remote.resolvedKey(environment: ["SOME_KEY": "env"]), "sk-tts")
        let env = SpeechSettings(engine: .remote, apiKey: "ignored", keyEnv: "SOME_KEY")
        XCTAssertEqual(env.resolvedKey(environment: ["SOME_KEY": "from-env"]), "from-env")
        XCTAssertEqual(LLMKeySource(keyEnv: "K", apiKey: "a"), .env)
        XCTAssertEqual(LLMKeySource(keyEnv: "", apiKey: "a"), .manual)
        XCTAssertEqual(LLMKeySource(keyEnv: "", apiKey: ""), .none)
    }

    func testTheKeyIsNeverPersisted() throws {
        let data = try JSONEncoder().encode(remote.persisted)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sk-tts"))
        XCTAssertEqual(try JSONDecoder().decode(SpeechSettings.self, from: data).baseUrl, remote.baseUrl)
    }

    func testSettingsPickTheBackend() {
        XCTAssertTrue(SpeechSettings().makeBackend() is LocalSpeechBackend)
        let backend = remote.makeBackend()
        XCTAssertTrue(backend is RemoteSpeechBackend)
        XCTAssertEqual((backend as? RemoteSpeechBackend)?.settings, remote)
        XCTAssertEqual(LocalSpeechBackend().maxPieceLength, KokoroSpeech.maxPieceLength)
        XCTAssertEqual(LocalSpeechBackend().preparationShare, 0.5)
        XCTAssertEqual(backend.preparationShare, 0)
        XCTAssertEqual(LocalSpeechBackend().parallelRequests, 1)   // one Kokoro call at a time
        XCTAssertEqual(SpeechSettings(engine: .remote, baseUrl: "http://x", parallelRequests: 6).makeBackend().parallelRequests, 6)
        XCTAssertGreaterThan(backend.maxPieceLength, KokoroSpeech.maxPieceLength)
        XCTAssertEqual(backend.pieces(of: String(repeating: "Word word. ", count: 50)).count, 1)
    }
}

final class RemoteSpeechClientTests: PapertalkTestCase {
    func testSpeechRequest() throws {
        let req = try RemoteSpeechClient(settings: remote).speechRequest(text: "Hello there.", voice: "af_heart", speed: 1.25)
        XCTAssertEqual(req.url?.absoluteString, "http://tts.test/api/v1/audio/speech")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-tts")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let b = body(req)
        XCTAssertEqual(b["model"] as? String, "kokoro")
        XCTAssertEqual(b["input"] as? String, "Hello there.")
        XCTAssertEqual(b["voice"] as? String, "af_heart")
        XCTAssertEqual(b["response_format"] as? String, "wav")
        XCTAssertEqual(b["speed"] as? Double, 1.25)

        let fromEnv = try RemoteSpeechClient(settings: SpeechSettings(engine: .remote, baseUrl: "https://tts.test", keyEnv: "K"),
                                             apiKey: "env-key").speechRequest(text: "x", voice: "v", speed: 1)
        XCTAssertEqual(fromEnv.value(forHTTPHeaderField: "Authorization"), "Bearer env-key")
        XCTAssertEqual(RemoteSpeechBackend(settings: remote).apiKey, "sk-tts")

        let bare = SpeechSettings(engine: .remote, baseUrl: "https://tts.test")
        let plain = try RemoteSpeechClient(settings: bare).speechRequest(text: "x", voice: "v", speed: 1)
        XCTAssertNil(plain.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body(plain)["model"] as? String, SpeechSettings.fallbackModel)
    }

    func testBadURLs() {
        XCTAssertThrowsError(try RemoteSpeechClient(settings: SpeechSettings(engine: .remote)).endpoint("audio/speech")) {
            XCTAssertEqual($0 as? RemoteSpeechError, .noURL)
        }
        for url in ["localhost:3000", "ftp://x", "not a url"] {
            XCTAssertThrowsError(try RemoteSpeechClient(settings: SpeechSettings(engine: .remote, baseUrl: url)).endpoint("audio/speech"), url) {
                XCTAssertEqual($0 as? RemoteSpeechError, .badURL, url)
            }
        }
    }

    func testParsesTheListShapesServersUse() {
        XCTAssertEqual(RemoteSpeechClient.parseIDs(json(["voices": ["af_heart", "am_adam", "af_heart"]]), keys: ["voices"]), ["af_heart", "am_adam"])
        XCTAssertEqual(RemoteSpeechClient.parseIDs(json(["voices": [["id": "alloy", "name": "Alloy"], ["name": "echo"]]]), keys: ["voices"]), ["alloy", "echo"])
        XCTAssertEqual(RemoteSpeechClient.parseIDs(json(["data": [["id": "tts-1"], ["id": "kokoro"]]]), keys: ["models", "data"]), ["tts-1", "kokoro"])
        XCTAssertEqual(RemoteSpeechClient.parseIDs(json(["models": [["id": "tts-1-hd"]]]), keys: ["models", "data"]), ["tts-1-hd"])
        XCTAssertEqual(RemoteSpeechClient.parseIDs(json(["a", " ", "b"]), keys: []), ["a", "b"])
        XCTAssertEqual(RemoteSpeechClient.parseIDs(json([["voice_id": "v1"]]), keys: []), ["v1"])
        XCTAssertNil(RemoteSpeechClient.parseIDs(json(["other": 1]), keys: ["voices"]))
        XCTAssertNil(RemoteSpeechClient.parseIDs(Data("<html>".utf8), keys: ["voices"]))
    }

    func testErrorDetails() {
        XCTAssertEqual(RemoteSpeechClient.errorDetail(json(["detail": "Voice not found"])), "Voice not found")
        XCTAssertEqual(RemoteSpeechClient.errorDetail(json(["error": ["message": "Bad model"]])), "Bad model")
        XCTAssertEqual(RemoteSpeechClient.errorDetail(json(["error": "nope"])), "nope")
        XCTAssertEqual(RemoteSpeechClient.errorDetail(json(["message": "m"])), "m")
        XCTAssertNil(RemoteSpeechClient.errorDetail(Data("oops".utf8)))
        XCTAssertEqual(RemoteSpeechError.http(400, "Voice not found").errorDescription, "The speech server answered HTTP 400: Voice not found")
        XCTAssertEqual(RemoteSpeechError.http(400, nil).errorDescription, "The speech server answered HTTP 400.")
        XCTAssertTrue(RemoteSpeechError.unreachable("http://x").errorDescription!.contains("http://x"))
    }

    /// Open WebUI: models at /audio/models, voices at /audio/voices, both behind the key.
    func testListsOpenWebUIModelsAndVoices() async throws {
        var paths: [String] = []
        MockLLM.install { req in
            paths.append(req.url!.path)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-tts")
            switch req.url!.path {
            case "/api/v1/audio/models": return (200, json(["models": [["id": "tts-1"], ["id": "tts-1-hd"]]]))
            case "/api/v1/audio/voices": return (200, json(["voices": [["id": "alloy", "name": "alloy"], ["id": "nova", "name": "nova"]]]))
            default: return (404, Data())
            }
        }
        let client = RemoteSpeechClient(settings: remote)
        let models = try await client.listModels()
        let voices = try await client.listVoices()
        XCTAssertEqual(models, ["tts-1", "tts-1-hd"])
        XCTAssertEqual(voices, ["alloy", "nova"])
        XCTAssertEqual(paths, ["/api/v1/audio/models", "/api/v1/audio/voices"])
    }

    /// Kokoro-FastAPI style: no /audio/models, an OpenAI /models list instead.
    func testFallsBackToModelsAndCopesWithoutVoices() async throws {
        var paths: [String] = []
        MockLLM.install { req in
            paths.append(req.url!.path)
            switch req.url!.path {
            case "/v1/models": return (200, json(["data": [["id": "kokoro"]]]))
            default: return (404, json(["detail": "Not Found"]))
            }
        }
        let client = RemoteSpeechClient(settings: SpeechSettings(engine: .remote, baseUrl: "http://k.test/v1"))
        let models = try await client.listModels()
        let voices = try await client.listVoices()
        XCTAssertEqual(models, ["kokoro"])
        XCTAssertEqual(voices, [])
        XCTAssertEqual(paths, ["/v1/audio/models", "/v1/models", "/v1/audio/voices"])
    }

    /// The URL copied from the LLM settings (Open WebUI's `/api`): audio is found under `/api/v1`.
    func testOpenWebUIChatURLFindsTheAudioUnderV1() async throws {
        var paths: [String] = []
        MockLLM.install { req in
            paths.append(req.url!.path)
            switch req.url!.path {
            case "/api/v1/audio/speech": return (200, Fixtures.silentWAV(seconds: 0.1))
            case "/api/v1/audio/models": return (200, json(["models": [["id": "tts-1"]]]))
            case "/api/v1/audio/voices": return (200, json(["voices": [["id": "af_heart", "name": "af_heart"]]]))
            case "/api/models": return (200, json(["data": [["id": "an-llm"]]]))
            default: return (405, json(["detail": "Method Not Allowed"]))
            }
        }
        let settings = SpeechSettings(engine: .remote, baseUrl: "http://owui.test:3000/api", apiKey: "k")
        let client = RemoteSpeechClient(settings: settings)
        XCTAssertEqual(client.audioRoots, ["http://owui.test:3000/api/v1", "http://owui.test:3000/api"])
        let audio = try await RemoteSpeechBackend(settings: settings).synthesize(text: "Hi.", voice: "af_heart", speed: 1)
        let models = try await client.listModels()
        let voices = try await client.listVoices()
        XCTAssertEqual(KokoroSpeech.wavDuration(audio), 0.1, accuracy: 0.01)
        XCTAssertEqual(models, ["tts-1"])   // not the LLMs at /api/models
        XCTAssertEqual(voices, ["af_heart"])
        XCTAssertEqual(paths, ["/api/v1/audio/speech", "/api/v1/audio/models", "/api/v1/audio/voices"])
    }

    func testNoSpeechEndpointSaysWhereItLooked() async {
        var paths: [String] = []
        MockLLM.install { req in paths.append(req.url!.path); return (405, json(["detail": "Method Not Allowed"])) }
        let settings = SpeechSettings(engine: .remote, baseUrl: "http://owui.test:3000/api/")
        do { _ = try await RemoteSpeechBackend(settings: settings).synthesize(text: "x", voice: "af_heart", speed: 1); XCTFail("expected an error") }
        catch {
            XCTAssertEqual(error as? RemoteSpeechError, .noSpeechEndpoint("http://owui.test:3000/api"))
            XCTAssertEqual(error.localizedDescription, "There's no /audio/speech under http://owui.test:3000/api. "
                + "Check the speech server URL: for Open WebUI it's the server's address followed by /api/v1.")
        }
        XCTAssertEqual(paths, ["/api/v1/audio/speech", "/api/audio/speech"])
    }

    func testEmptyAudioModelsFallsBackToo() async throws {
        MockLLM.install { req in
            req.url!.path.hasSuffix("audio/models") ? (200, json(["models": []])) : (200, json(["data": [["id": "m"]]]))
        }
        let models = try await RemoteSpeechClient(settings: remote).listModels()
        XCTAssertEqual(models, ["m"])
    }

    func testRejectedKeyAndUnreachableServer() async {
        MockLLM.install { _ in (401, json(["detail": "Not authenticated"])) }
        do { _ = try await RemoteSpeechClient(settings: remote).listModels(); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? RemoteSpeechError, .unauthorized) }

        MockLLM.install { _ in (-1, Data()) }
        do { _ = try await RemoteSpeechClient(settings: remote, attempts: 1).listVoices(); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? RemoteSpeechError, .unreachable("http://tts.test/api/v1")) }
    }

    func testBackendSendsTheCastsVoiceAndNormalizesTheAudio() async throws {
        var sent: [[String: Any]] = []
        MockLLM.install { req in
            sent.append(body(req))
            return (200, wav(rate: 48_000, channels: 2, bits: 16, frames: 24_000))
        }
        let out = try await RemoteSpeechBackend(settings: remote).synthesize(text: "Hi.", voice: "bf_emma", speed: 0.95)
        XCTAssertTrue(try SpeechAudio.parseWAV(out).isCanonical)
        XCTAssertEqual(KokoroSpeech.wavDuration(out), 0.5, accuracy: 0.01)
        XCTAssertEqual(sent.first?["voice"] as? String, "bf_emma")
        XCTAssertEqual(sent.first?["input"] as? String, "Hi.")
    }

    func testJSONInsteadOfAudioIsAnError() async {
        MockLLM.install { _ in (200, json(["detail": "TTS engine not configured"])) }
        do { _ = try await RemoteSpeechBackend(settings: remote).synthesize(text: "x", voice: "af_heart", speed: 1); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? RemoteSpeechError, .notAudio("TTS engine not configured")) }

        MockLLM.install { _ in (400, json(["detail": "Voice not found"])) }
        do { _ = try await RemoteSpeechBackend(settings: remote).synthesize(text: "x", voice: "af_heart", speed: 1); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? RemoteSpeechError, .http(400, "Voice not found")) }
    }

    func testPrepareChecksTheURLWithoutCallingTheServer() async throws {
        try await RemoteSpeechBackend(settings: remote).prepare()
        do { try await RemoteSpeechBackend(settings: SpeechSettings(engine: .remote)).prepare(); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? RemoteSpeechError, .noURL) }
    }
}

final class SpeechSettingsFormTests: PapertalkTestCase {
    func testSettingsAreTrimmedAndKeepRemoteFields() {
        var f = SpeechSettingsForm(SpeechSettings())
        XCTAssertFalse(f.isRemote)
        XCTAssertFalse(f.canFetchCatalog)
        f.engine = .remote
        XCTAssertFalse(f.canFetchCatalog)
        f.baseUrl = " http://tts.test/api/v1// "
        f.keySource = .manual
        f.manualKey = " sk "
        f.model = " tts-1 "
        f.parallelRequests = 8
        XCTAssertEqual(f.parallelLabel, "8 at a time")
        XCTAssertTrue(f.canFetchCatalog)
        XCTAssertEqual(f.settings, SpeechSettings(engine: .remote, baseUrl: "http://tts.test/api/v1", apiKey: "sk",
                                                  model: "tts-1", parallelRequests: 8))
        f.engine = .local
        XCTAssertEqual(f.settings.engine, .local)
        XCTAssertEqual(f.settings.baseUrl, "http://tts.test/api/v1")
        XCTAssertFalse(f.canFetchCatalog)
        XCTAssertEqual(SpeechSettingsForm(remote).settings.apiKey, "sk-tts")
    }

    func testTheKeyCanComeFromTheEnvironment() {
        var f = SpeechSettingsForm(SpeechSettings(engine: .remote, baseUrl: "http://tts.test", apiKey: "typed"),
                                   setEnvVars: ["OPENWEBUI_API_KEY"])
        XCTAssertEqual(f.keySource, .manual)
        XCTAssertEqual(f.manualKey, "typed")
        f.keySource = .env
        f.keySourceChanged()
        XCTAssertEqual(f.selectedEnv, "OPENWEBUI_API_KEY")
        XCTAssertEqual(f.effectiveKey(environment: ["OPENWEBUI_API_KEY": "from-env"]), "from-env")
        // Only the chosen source is saved.
        XCTAssertEqual(f.settings.keyEnv, "OPENWEBUI_API_KEY")
        XCTAssertEqual(f.settings.apiKey, "")
        f.keySource = .none
        XCTAssertEqual(f.settings.keyEnv, "")
        XCTAssertEqual(f.settings.apiKey, "")
        XCTAssertEqual(f.effectiveKey(environment: ["OPENWEBUI_API_KEY": "from-env"]), "")

        let saved = SpeechSettingsForm(SpeechSettings(engine: .remote, keyEnv: "MY_KEY"), setEnvVars: [])
        XCTAssertEqual(saved.keySource, .env)
        XCTAssertEqual(saved.envOptions, ["MY_KEY"])   // kept even though it isn't set now
        XCTAssertEqual(SpeechSettingsForm(SpeechSettings(), setEnvVars: []).keySource, .none)
    }

    func testFetchCatalogSendsTheFormsKey() async {
        var auth: [String?] = []
        MockLLM.install { req in
            auth.append(req.value(forHTTPHeaderField: "Authorization"))
            return (404, Data())
        }
        var f = SpeechSettingsForm(SpeechSettings(engine: .remote, baseUrl: "http://tts.test"), setEnvVars: [])
        f.keySource = .manual
        f.manualKey = "sk-typed"
        _ = await f.fetchCatalog()
        XCTAssertEqual(Set(auth), ["Bearer sk-typed"])
    }

    func testApplyingTheCatalog() {
        var f = SpeechSettingsForm(remote)
        f.model = "gone"
        let note = f.apply(SpeechCatalog(models: ["tts-1", "kokoro"], voices: ["af_heart", "am_michael", "bf_emma"]))
        XCTAssertEqual(note, FormNote(text: "Found 2 models and 3 voices.", isError: false))
        XCTAssertEqual(f.model, "kokoro")
        XCTAssertTrue(f.showsModelPicker)
        f.model = "tts-1"
        _ = f.apply(SpeechCatalog(models: ["tts-1", "kokoro"]))
        XCTAssertEqual(f.model, "tts-1")   // still offered: kept
    }

    func testWarnsWhenTheServerHasNoKokoroVoices() {
        var f = SpeechSettingsForm(remote)
        XCTAssertEqual(f.apply(SpeechCatalog(models: ["tts-1"], voices: ["alloy", "nova"])),
                       FormNote(text: SpeechSettingsForm.notKokoroVoices, isError: true))
    }

    func testNotesWhenTheServerListsLittle() {
        var f = SpeechSettingsForm(remote)
        XCTAssertEqual(f.apply(SpeechCatalog())?.text, "The server didn't list models or voices. Type the model name.")
        XCTAssertEqual(f.model, "kokoro")
        XCTAssertFalse(f.showsModelPicker)
        XCTAssertEqual(SpeechSettingsForm.note(models: 1, voices: 0).text, "Found 1 model.")
        XCTAssertEqual(SpeechSettingsForm.note(models: 0, voices: 2).text, "Found 2 voices. Type the model name.")
        let failed = f.apply(SpeechCatalog(error: "Couldn't reach it."))
        XCTAssertEqual(failed, FormNote(text: "Couldn't reach it.", isError: true))
    }

    func testFetchCatalogAsksTheServer() async {
        MockLLM.install { req in
            switch req.url!.path {
            case "/api/v1/audio/models": return (200, json(["models": [["id": "tts-1"]]]))
            case "/api/v1/audio/voices": return (200, json(["voices": [["id": "af_heart"]]]))
            default: return (404, Data())
            }
        }
        let catalog = await SpeechSettingsForm(remote).fetchCatalog()
        XCTAssertEqual(catalog, SpeechCatalog(models: ["tts-1"], voices: ["af_heart"]))

        MockLLM.install { _ in (403, Data()) }
        let rejected = await SpeechSettingsForm(remote).fetchCatalog()
        XCTAssertEqual(rejected.error, RemoteSpeechError.unauthorized.errorDescription)

        MockLLM.install { _ in (-1, Data()) }
        let down = await SpeechSettingsForm(remote).fetchCatalog()
        XCTAssertEqual(down.error, "Couldn't reach the speech server at http://tts.test/api/v1. Check the URL and that the server is running.")
    }

    func testWordingAndSummary() {
        XCTAssertEqual(SpeechSettingsForm(SpeechSettings()).summary.map(\.value), ["On \(Device.this)"])
        XCTAssertEqual(SpeechSettingsForm(remote).summary.map(\.value), ["http://tts.test/api/v1", "kokoro"])
        XCTAssertEqual(SpeechSettingsForm(SpeechSettings(engine: .remote)).summary.map(\.value),
                       ["Speech server (no URL)", SpeechSettings.fallbackModel])
        XCTAssertEqual(SpeechSettingsForm.engineTitle(.remote), "Speech server")
        XCTAssertTrue(SpeechSettingsForm.engineDescription(.local).contains("Kokoro"))
        XCTAssertTrue(SpeechSettingsForm.engineDescription(.remote).contains("Open WebUI"))
    }
}

/// The store's synthesis paths go through the backend it was given.
@MainActor
final class SpeechBackendStoreTests: PapertalkTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storage: LocalStorage!

    override func setUp() {
        super.setUp()
        dir = Fixtures.tempDir()
        storage = LocalStorage(root: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A finished script without audio, loaded by the store's startup scan.
    private func storeWithScript(_ backend: any SpeechBackend,
                                 turns: [(String, String)] = [("Ada", "Hello and welcome."), ("Bob", "Thanks for having me.")]) async -> (AppStore, String) {
        let p = Fixtures.paper(hasScript: true, hasAudio: false)
        await storage.save(p, K.paper(p.id))
        await storage.save(Fixtures.transcript(turns), K.transcript(p.id))
        let store = AppStore(storage: storage, speech: backend)
        await waitUntil { store.papers[p.id] != nil }
        return (store, p.id)
    }

    func testTheStoreAndPlayerUseTheGivenBackend() async {
        let fake = FakeSpeechBackend()
        let store = AppStore(storage: storage, speech: fake)
        XCTAssertTrue(store.speechBackend as AnyObject === fake)
        XCTAssertTrue(store.player.speechBackend as AnyObject === fake)
    }

    func testRegeneratingAudioUsesTheBackend() async throws {
        let fake = FakeSpeechBackend()
        let (store, id) = await storeWithScript(fake)
        store.regenerateAudio(id)
        await waitUntil { store.papers[id]?.hasAudio == true }
        XCTAssertEqual(fake.calls.map(\.voice), ["af_heart", "af_bella"])
        XCTAssertEqual(fake.calls.map(\.text), ["Hello and welcome.", "Thanks for having me."])
        let manifest = await storage.exists(AudioManifest.self, K.audioManifest(id))
        XCTAssertEqual(manifest?.durations.count, 2)
        XCTAssertEqual(manifest?.durations.first ?? 0, 0.5, accuracy: 0.01)
    }

    func testRegeneratingAudioOnASpeechServer() async throws {
        let voices = Collected<String>()
        MockLLM.install { req in
            guard req.url?.path == "/api/v1/audio/speech" else { return (404, Data()) }
            voices.add(body(req)["voice"] as? String ?? "")
            return (200, wav(rate: 48_000, channels: 2, bits: 16, frames: 48_000))
        }
        let (store, id) = await storeWithScript(remote.makeBackend())
        store.regenerateAudio(id)
        await waitUntil { store.papers[id]?.hasAudio == true }
        XCTAssertEqual(voices.all.sorted(), ["af_bella", "af_heart"])   // the cast's own voices
        let turn = try await storage.read(K.turn(id, 0))
        XCTAssertTrue(try SpeechAudio.parseWAV(turn).isCanonical)
        XCTAssertEqual(KokoroSpeech.wavDuration(turn), 1.0, accuracy: 0.01)
    }

    func testAServerErrorLeavesAResumableAudioError() async {
        MockLLM.install { _ in (401, Data()) }
        let (store, id) = await storeWithScript(remote.makeBackend())
        store.regenerateAudio(id)
        await waitUntil { store.papers[id]?.state == "error" }
        XCTAssertEqual(store.papers[id]?.hasAudio, false)
        XCTAssertTrue(store.papers[id]?.statusError?.contains("rejected the API key") == true)
    }

    /// A long script voiced several turns at a time: every turn lands in its
    /// own slot, in order, and never more calls run than the backend allows.
    func testParallelBakeKeepsTurnsInOrder() async throws {
        let fake = FakeSpeechBackend(parallel: 3, delayMs: 30)
        let turns = (0..<10).map { i in (i % 2 == 0 ? "Ada" : "Bob", "Turn \(i).") }
        let (store, id) = await storeWithScript(fake, turns: turns)
        store.regenerateAudio(id)
        await waitUntil(timeout: 5) { store.papers[id]?.hasAudio == true }
        XCTAssertEqual(fake.calls.count, 10)
        XCTAssertEqual(fake.mostInFlight, 3)
        let manifest = await storage.exists(AudioManifest.self, K.audioManifest(id))
        XCTAssertEqual(manifest?.durations.count, 10)
        for i in 0..<10 { _ = try await storage.read(K.turn(id, i)) }
    }

    func testLocalBakeRunsOneAtATime() async {
        let fake = FakeSpeechBackend(parallel: 1, delayMs: 10)
        let (store, id) = await storeWithScript(fake, turns: (0..<5).map { ("Ada", "Turn \($0).") })
        store.regenerateAudio(id)
        await waitUntil { store.papers[id]?.hasAudio == true }
        XCTAssertEqual(fake.mostInFlight, 1)
    }

    /// A failure keeps the finished turns and says where voicing will continue.
    func testParallelBakeFailureResumes() async throws {
        let fake = FakeSpeechBackend(parallel: 4, failOn: "Turn 5.")
        let (store, id) = await storeWithScript(fake, turns: (0..<8).map { ("Ada", "Turn \($0).") })
        store.regenerateAudio(id)
        await waitUntil { store.papers[id]?.state == "error" }
        XCTAssertTrue(store.papers[id]?.statusError?.hasPrefix("Voicing stopped at section 6 of 8") == true,
                      store.papers[id]?.statusError ?? "")
        var kept = 0
        for i in 0..<8 where (try? await storage.read(K.turn(id, i))) != nil { kept += 1 }
        XCTAssertGreaterThan(kept, 0)   // turns voiced before the failure stay on disk
        XCTAssertLessThan(kept, 8)
    }

    // MARK: stopping

    /// A long, slow voicing that can be stopped part-way.
    private func slowRegenerate(_ fake: FakeSpeechBackend, turns: Int = 40) async -> (AppStore, String) {
        let (store, id) = await storeWithScript(fake, turns: (0..<turns).map { ("Ada", "Turn \($0).") })
        store.regenerateAudio(id)
        await waitUntil { fake.calls.count >= 2 }
        XCTAssertTrue(store.isRunning(id))
        XCTAssertTrue(PaperPresentation.canStop(store.papers[id]!))
        return (store, id)
    }

    func testStoppingKeepsVoicedSectionsAndResumes() async throws {
        let fake = FakeSpeechBackend(parallel: 2, delayMs: 40)
        let (store, id) = await slowRegenerate(fake)
        let storage = self.storage!
        await waitUntil { (try? await storage.read(K.turn(id, 0))) != nil }   // one section saved
        store.stopConversion(id)
        await waitUntil { store.papers[id]?.state == "error" }
        await waitUntil { !store.isRunning(id) }
        let p = try XCTUnwrap(store.papers[id])
        XCTAssertEqual(p.statusError, ConversionPresentation.stoppedMessage)
        XCTAssertEqual(PaperPresentation.failureTitle(p), "Conversion stopped")
        XCTAssertFalse(p.hasAudio)
        XCTAssertNil(store.toast.flatMap { $0.contains("failed") ? $0 : nil })
        let onDisk = await storage.exists(Paper.self, K.paper(id))
        XCTAssertEqual(onDisk?.statusError, ConversionPresentation.stoppedMessage)

        // Nothing more is voiced once stopped.
        let callsAtStop = fake.calls.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.calls.count, callsAtStop)
        XCTAssertLessThan(callsAtStop, 40)

        // Voicing again continues: only the missing sections are asked for.
        var kept = 0
        for i in 0..<40 where (try? await storage.read(K.turn(id, i))) != nil { kept += 1 }
        XCTAssertGreaterThan(kept, 0)
        let resume = FakeSpeechBackend(parallel: 8)
        let again = AppStore(storage: storage, speech: resume)
        await waitUntil { again.papers[id] != nil }
        again.regenerateAudio(id)
        await waitUntil(timeout: 5) { again.papers[id]?.hasAudio == true }
        XCTAssertEqual(resume.calls.count, 40 - kept)
    }

    func testDeletingAConvertingPaperStopsItFirst() async throws {
        let fake = FakeSpeechBackend(parallel: 2, delayMs: 40)
        let (store, id) = await slowRegenerate(fake)
        store.delete(id)
        await waitUntil { store.papers[id] == nil }
        XCTAssertFalse(store.isRunning(id))
        let callsAtDelete = fake.calls.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.calls.count, callsAtDelete)
        // The folder is gone and stays gone: nothing wrote into it afterwards.
        let folder = dir.appendingPathComponent("papers/\(id)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A paper waiting for another paper's audio can be stopped without
    /// disturbing the one being voiced.
    func testStoppingAPaperWaitingForTheGate() async throws {
        let fake = FakeSpeechBackend(parallel: 1, delayMs: 30)
        let (store, first) = await slowRegenerate(fake, turns: 10)
        let second = Fixtures.paper(hasScript: true, hasAudio: false)
        await storage.save(second, K.paper(second.id))
        await storage.save(Fixtures.transcript([("Bob", "Waiting here.")]), K.transcript(second.id))
        store.papers[second.id] = second
        store.regenerateAudio(second.id)
        await waitUntil { store.papers[second.id]?.message == "Waiting for another paper's audio…" }
        store.stopConversion(second.id)
        await waitUntil { store.papers[second.id]?.state == "error" }
        XCTAssertEqual(store.papers[second.id]?.statusError, ConversionPresentation.stoppedMessage)
        await waitUntil(timeout: 5) { store.papers[first]?.hasAudio == true }
        XCTAssertFalse(fake.calls.contains { $0.text == "Waiting here." })
        XCTAssertFalse(store.audioGate.isBusy)
    }

    func testOnlyLocalSamplesWaitForAModel() async {
        XCTAssertTrue(PlayerController(speechBackend: LocalSpeechBackend()).sampleLoadsModel)
        XCTAssertFalse(PlayerController(speechBackend: remote.makeBackend()).sampleLoadsModel)
        XCTAssertTrue(LocalSpeechBackend().loadsModel)
    }

    func testLivePlaybackRendersWithTheBackend() async {
        let fake = FakeSpeechBackend(seconds: 0.25)
        let player = PlayerController(speechBackend: fake)
        let long = String(repeating: "A short sentence here. ", count: 4)
        player.prepare(transcript: Fixtures.transcript([("Ada", "Hi."), ("Bob", long)]), voiceMap: ["Ada": "af_heart", "Bob": "am_michael"])
        await waitUntil { player.renderedCount == 2 }
        // The long turn went out in the backend's pieces (40 characters) and came back as one turn.
        XCTAssertEqual(fake.calls.first?.voice, "af_heart")
        XCTAssertGreaterThan(fake.calls.count, 2)
        XCTAssertTrue(fake.calls.dropFirst().allSatisfy { $0.voice == "am_michael" && $0.text.count <= 40 })
        XCTAssertEqual(player.duration, 0.25 + 0.35 + 0.25 * Double(fake.calls.count - 1), accuracy: 0.01)
        player.stopAll()
    }
}
