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
    /// Longest piece of text sent in one call (see `KokoroSpeech.pieces`).
    var maxPieceLength: Int { get }
    /// Get ready for synthesis; reports (fraction 0…1, wording) while it works.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// `text` spoken by the cast's Kokoro `voice`, as 24 kHz mono 16-bit WAV.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
}

extension SpeechBackend {
    func prepare() async throws { try await prepare { _, _ in } }

    /// A turn split into the pieces this backend takes per call.
    func pieces(of text: String) -> [String] { KokoroSpeech.pieces(of: text, max: maxPieceLength) }
}

/// Kokoro on this machine (Core ML on macOS, ONNX on Linux): the one shared engine.
struct LocalSpeechBackend: SpeechBackend {
    var preparingMessage: String { "Preparing Kokoro…" }
    var preparationShare: Double { 0.5 }
    var loadsModel: Bool { true }
    var maxPieceLength: Int { KokoroSpeech.maxPieceLength }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        // No-op when the models are cached, but still reports progress.
        try await KokoroAneResourceDownloader.ensureModels(variant: .english) { p in
            let phase: String = {
                switch p.phase {
                case .listing: return "Contacting model server…"
                case .downloading: return "Downloading Kokoro model…"
                case .compiling: return "Compiling Kokoro model…"
                }
            }()
            progress(p.fractionCompleted, phase)
        }
        try await KokoroEngine.shared.prepare()
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await KokoroEngine.shared.synthesize(text: text, voice: voice, speed: speed)
    }
}

/// An OpenAI-compatible text-to-speech server (Open WebUI, Kokoro-FastAPI,
/// OpenAI). Nothing is loaded locally, which spares the memory Core ML needs.
struct RemoteSpeechBackend: SpeechBackend {
    let settings: SpeechSettings
    /// Resolved once, so an env-sourced key isn't looked up for every piece.
    let apiKey: String

    init(settings: SpeechSettings, apiKey: String? = nil) {
        self.settings = settings
        self.apiKey = apiKey ?? settings.resolvedKey()
    }

    var preparingMessage: String { "Connecting to the speech server…" }
    var preparationShare: Double { 0 }
    var loadsModel: Bool { false }
    /// Memory isn't ours to save here, and longer pieces mean fewer requests and
    /// smoother intonation; still well under OpenAI's 4,096-character limit.
    var maxPieceLength: Int { 1000 }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        _ = try RemoteSpeechClient(settings: settings, apiKey: apiKey).endpoint("audio/speech")
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        let client = RemoteSpeechClient(settings: settings, apiKey: apiKey)
        return try SpeechAudio.normalizedWAV(try await client.speech(text: text, voice: settings.serverVoice(for: voice), speed: speed))
    }
}

enum RemoteSpeechError: Error, LocalizedError, Equatable {
    case noURL, badURL, unreachable(String), unauthorized, http(Int, String?), notAudio(String?), noSpeechEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .noURL:
            return "No speech server is set. Add its URL in Settings → Voices, or switch to voices on \(Device.this)."
        case .badURL:
            return "The speech server URL isn't valid. It should look like http://localhost:3000/api/v1."
        case .unreachable(let base):
            return "Couldn't reach the speech server at \(base). Check the URL and that the server is running."
        case .unauthorized:
            return "The speech server rejected the API key. Check the key in Settings → Voices."
        case .http(let code, let detail):
            return "The speech server answered HTTP \(code)" + (detail.map { ": \($0)" } ?? ".")
        case .notAudio(let detail):
            return "The speech server didn't send audio" + (detail.map { ": \($0)" } ?? ".")
        case .noSpeechEndpoint(let base):
            return "There's no /audio/speech under \(base). Check the speech server URL: "
                + "for Open WebUI it's the server's address followed by /api/v1."
        }
    }
}

/// HTTP calls to an OpenAI-compatible speech server: `POST /audio/speech`, and
/// the model and voice lists, which servers expose under different paths (or not at all).
struct RemoteSpeechClient {
    let settings: SpeechSettings
    let apiKey: String
    var attempts = 3

    init(settings: SpeechSettings, apiKey: String? = nil, attempts: Int = 3) {
        self.settings = settings
        self.apiKey = apiKey ?? settings.resolvedKey()
        self.attempts = attempts
    }

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

    func endpoint(_ path: String, at root: String? = nil) throws -> URL {
        guard !base.isEmpty else { throw RemoteSpeechError.noURL }
        guard let url = URL(string: (root ?? base) + "/" + path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { throw RemoteSpeechError.badURL }
        return url
    }

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
    var isWhitespaceByte: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}
