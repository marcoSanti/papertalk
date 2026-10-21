// Speech synthesis behind one protocol: Kokoro on this machine (`LocalSpeechBackend`) or an
// OpenAI-compatible speech server (`RemoteSpeechBackend`, over `RemoteSpeechClient`).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Where speech is synthesized. Baking at import, regenerating, live playback
/// and voice samples all go through the backend `SpeechSettings.makeBackend()`
/// returns, so they always agree.
protocol SpeechBackend: Sendable {
    /// Progress-bar wording while the backend gets ready.
    var preparingMessage: String { get }
    /// Share of the audio progress band `prepare` reports on (model download).
    var preparationShare: Double { get }
    /// Whether the first call loads a model here, which makes it slow.
    var loadsModel: Bool { get }
    /// Turns voiced at once while baking.
    var parallelRequests: Int { get }
    /// Longest piece of text sent in one call (see `KokoroSpeech.pieces`).
    var maxPieceLength: Int { get }
    /// Get ready for synthesis; reports (fraction 0…1, wording) while it works.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// `text` spoken by the cast's Kokoro `voice`, as 24 kHz mono 16-bit WAV.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
}

extension SpeechBackend {
    /// Get ready without reporting progress.
    func prepare() async throws { try await prepare { _, _ in } }

    /// A turn split into the pieces this backend takes per call.
    func pieces(of text: String) -> [String] { KokoroSpeech.pieces(of: text, max: maxPieceLength) }

    /// A whole turn as one WAV, its pieces voiced one after another.
    func speak(_ text: String, voice: String, speed: Float) async throws -> Data {
        var parts: [Data] = []
        for piece in pieces(of: text) {
            try Task.checkCancellation()
            parts.append(try await synthesize(text: piece, voice: voice, speed: speed))
        }
        return KokoroSpeech.joinWAVs(parts)
    }
}

/// Kokoro on this machine (Core ML on macOS, ONNX on Linux): the one shared engine.
/// Kokoro on this machine, through `KokoroEngine.shared`.
struct LocalSpeechBackend: SpeechBackend {
    /// The first half of the audio band is the model download and load.
    var preparingMessage: String { L("Preparing Kokoro…") }
    /// Half the audio band goes to the download and load.
    var preparationShare: Double { 0.5 }
    /// The model loads on first use, so the first sample is slow.
    var loadsModel: Bool { true }
    /// One model, one call at a time (see `KokoroEngine`, `AppStore.audioGate`).
    var parallelRequests: Int { 1 }
    /// Short pieces keep Core ML's memory flat (see `KokoroSpeech.maxPieceLength`).
    var maxPieceLength: Int { KokoroSpeech.maxPieceLength }

    /// Download the English Kokoro models if missing, then load them.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        // No-op when the models are cached, but still reports progress.
        try await KokoroAneResourceDownloader.ensureModels(variant: .english) { p in
            let phase: String = {
                switch p.phase {
                case .listing: return L("Contacting model server…")
                case .downloading: return L("Downloading Kokoro model…")
                case .compiling: return L("Compiling Kokoro model…")
                }
            }()
            progress(p.fractionCompleted, phase)
        }
        try await KokoroEngine.shared.prepare()
    }

    /// Through the one shared engine, never a second model.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await KokoroEngine.shared.synthesize(text: text, voice: voice, speed: speed)
    }
}

/// An OpenAI-compatible text-to-speech server (Open WebUI, Kokoro-FastAPI,
/// OpenAI). Nothing is loaded locally, which spares the memory Core ML needs.
struct RemoteSpeechBackend: SpeechBackend {
    /// The server, model and parallelism to use.
    let settings: SpeechSettings
    /// Resolved once, so an env-sourced key isn't looked up for every piece.
    let apiKey: String

    /// `apiKey` overrides the settings' key (tests).
    init(settings: SpeechSettings, apiKey: String? = nil) {
        self.settings = settings
        self.apiKey = apiKey ?? settings.resolvedKey()
    }

    /// Nothing to download, so no share of the band for preparing.
    var preparingMessage: String { L("Connecting to the speech server…") }
    /// Nothing to prepare, so voicing gets the whole band.
    var preparationShare: Double { 0 }
    /// Nothing loads here.
    var loadsModel: Bool { false }
    /// As many turns at once as the user allows.
    var parallelRequests: Int { settings.parallelRequests }
    /// Memory isn't ours to save here, and longer pieces mean fewer requests and
    /// smoother intonation; still well under OpenAI's 4,096-character limit.
    var maxPieceLength: Int { 1000 }

    /// Only checks the URL; the server is first asked for audio by the first turn.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        _ = try RemoteSpeechClient(settings: settings, apiKey: apiKey).endpoint("audio/speech")
    }

    /// One request per piece, normalized to the stored WAV layout.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        let client = RemoteSpeechClient(settings: settings, apiKey: apiKey)
        return try SpeechAudio.normalizedWAV(try await client.speech(text: text, voice: voice, speed: speed))
    }
}

/// What went wrong talking to a speech server, worded for the user.
enum RemoteSpeechError: Error, LocalizedError, Equatable {
    case noURL, badURL, unreachable(String), unauthorized, http(Int, String?), notAudio(String?), noSpeechEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .noURL:
            return L("No speech server is set. Add its URL in Settings → Voices, or switch to voices on {0}.", Device.this)
        case .badURL:
            return L("The speech server URL isn't valid. It should look like http://localhost:3000/api/v1.")
        case .unreachable(let base):
            return L("Couldn't reach the speech server at {0}. Check the URL and that the server is running.", base)
        case .unauthorized:
            return L("The speech server rejected the API key. Check the key in Settings → Voices.")
        case .http(let code, let detail):
            return L("The speech server answered HTTP {0}", code) + (detail.map { ": \($0)" } ?? ".")
        case .notAudio(let detail):
            return L("The speech server didn't send audio") + (detail.map { ": \($0)" } ?? ".")
        case .noSpeechEndpoint(let base):
            return L("There's no /audio/speech under {0}. Check the speech server URL: for Open WebUI it's the server's address followed by /api/v1.", base)
        }
    }
}

/// HTTP calls to an OpenAI-compatible speech server: `POST /audio/speech`, and
/// the model and voice lists, which servers expose under different paths (or not at all).
struct RemoteSpeechClient {
    /// The server, model and key to use.
    let settings: SpeechSettings
    /// Resolved once (see `SpeechSettings.resolvedKey`).
    let apiKey: String
    /// Tries per request (transient failures are retried with backoff).
    var attempts = 3

    /// `apiKey` overrides the settings' key; `attempts` 1 for one-shot checks (Settings).
    init(settings: SpeechSettings, apiKey: String? = nil, attempts: Int = 3) {
        self.settings = settings
        self.apiKey = apiKey ?? settings.resolvedKey()
        self.attempts = attempts
    }

    /// The server URL without surrounding spaces or a trailing slash.
    var base: String {
        settings.baseUrl.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    /// Where the audio endpoints may live, in the order tried. Open WebUI's chat
    /// API is at `/api` but its audio at `/api/v1`, so a URL copied from the LLM
    /// settings still works.
    var audioRoots: [String] { base.hasSuffix("/api") ? [base + "/v1", base] : [base] }

    /// Status codes meaning "no such endpoint here".
    static let missing: Set<Int> = [404, 405, 501]

    /// `path` under `root` (default: `base`); throws when no URL is set or it isn't http(s).
    func endpoint(_ path: String, at root: String? = nil) throws -> URL {
        guard !base.isEmpty else { throw RemoteSpeechError.noURL }
        guard let url = URL(string: (root ?? base) + "/" + path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { throw RemoteSpeechError.badURL }
        return url
    }

    /// A request to `path` with the key and a generous timeout (long turns take a while).
    private func request(_ path: String, at root: String? = nil) throws -> URLRequest {
        var req = URLRequest(url: try endpoint(path, at: root))
        req.timeoutInterval = 120
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// The synthesis request. WAV is asked for so nothing needs decoding.
    func speechRequest(text: String, voice: String, speed: Float, at root: String? = nil) throws -> URLRequest {
        var req = try request("audio/speech", at: root)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/wav, audio/*", forHTTPHeaderField: "Accept")
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        let body: [String: Any] = [
            "model": model.isEmpty ? SpeechSettings.fallbackModel : model,
            "input": text,
            "voice": voice,
            "response_format": "wav",
            "speed": Double(speed),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// The server's audio bytes for one piece of text (in whatever format it sent).
    func speech(text: String, voice: String, speed: Float) async throws -> Data {
        for root in audioRoots {
            let (data, http) = try await send(try speechRequest(text: text, voice: voice, speed: speed, at: root))
            if Self.missing.contains(http.statusCode) { continue }
            try check(http, data)
            // Some servers report failures as JSON with a 200.
            if let first = data.first(where: { !$0.isWhitespaceByte }), first == UInt8(ascii: "{") {
                throw RemoteSpeechError.notAudio(Self.errorDetail(data))
            }
            return data
        }
        throw RemoteSpeechError.noSpeechEndpoint(base)
    }

    /// TTS models: Open WebUI lists them at `/audio/models`, OpenAI-style
    /// servers at `/models`. Empty when the server lists neither. `/models` is
    /// asked only at the URL as given: under Open WebUI's `/api` it lists LLMs.
    func listModels() async throws -> [String] {
        for root in audioRoots {
            if let ids = try await list("audio/models", at: root, keys: ["models", "data"]), !ids.isEmpty { return ids }
        }
        return try await list("models", at: base, keys: ["models", "data"]) ?? []
    }

    /// Voices at `/audio/voices` (Open WebUI, Kokoro-FastAPI). Empty when missing.
    func listVoices() async throws -> [String] {
        for root in audioRoots {
            if let ids = try await list("audio/voices", at: root, keys: ["voices", "data"]) { return ids }
        }
        return []
    }

    /// The ids at `path`, or nil when the server doesn't have that endpoint
    /// (or answers it with something that isn't a list, like a web page).
    private func list(_ path: String, at root: String, keys: [String]) async throws -> [String]? {
        let (data, http) = try await send(try request(path, at: root))
        if Self.missing.contains(http.statusCode) { return nil }
        try check(http, data)
        return Self.parseIDs(data, keys: keys)
    }

    /// Ids from the shapes servers use: `["a"]`, `{"voices": ["a"]}`,
    /// `{"data": [{"id": "a"}]}`, `{"voices": [{"id": "a", "name": "A"}]}`.
    static func parseIDs(_ data: Data, keys: [String]) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let items: [Any]
        if let array = json as? [Any] {
            items = array
        } else if let obj = json as? [String: Any], let found = keys.lazy.compactMap({ obj[$0] as? [Any] }).first {
            items = found
        } else {
            return nil
        }
        var seen = Set<String>()
        return items.compactMap { item -> String? in
            if let s = item as? String { return s }
            guard let o = item as? [String: Any] else { return nil }
            return (o["id"] ?? o["voice_id"] ?? o["name"]) as? String
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `detail` / `error.message` / `message` from a JSON error body.
    static func errorDetail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let d = obj["detail"] as? String { return d }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = obj["error"] as? String { return e }
        return obj["message"] as? String
    }

    /// Turn an error status into the `RemoteSpeechError` that explains it.
    private func check(_ http: HTTPURLResponse, _ data: Data) throws {
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw RemoteSpeechError.unauthorized
        default: throw RemoteSpeechError.http(http.statusCode, Self.errorDetail(data))
        }
    }

    /// Retries dropped connections and 5xx answers, like the LLM client.
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var last: Error = RemoteSpeechError.unreachable(base)
        for attempt in 0..<attempts {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw RemoteSpeechError.unreachable(base) }
                guard (500..<600).contains(http.statusCode), attempt < attempts - 1 else { return (data, http) }
            } catch is URLError {
                last = RemoteSpeechError.unreachable(base)
                if Task.isCancelled { throw CancellationError() }
            }
            if attempt < attempts - 1 {
                try await Task.sleep(nanoseconds: UInt64(min(1 << attempt, 8)) * 1_000_000_000)
            }
        }
        throw last
    }
}

private extension UInt8 {
    /// ASCII whitespace, for sniffing a JSON body.
    var isWhitespaceByte: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}
