// Linux stand-ins for FluidAudio's Kokoro API and the macOS `KokoroEngine`, backed by
// sherpa-onnx (ONNX Runtime on the CPU) through its C API.

#if os(Linux)
import CSherpaOnnx
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Kokoro v1.0 on Linux, behind the same API the shared code uses from FluidAudio and the
// macOS KokoroEngine, so AppStore, PlayerController and Kokoro.swift are unchanged. The
// model is sherpa-onnx's packaging of Kokoro v1.0 (the same 54 voices as macOS), with its
// own English lexicon and espeak-ng data for the phonemes.

/// The model variant; only English exists here.
enum KokoroAneVariant { case english }

/// Model download phases, as FluidAudio reports them (only listing and downloading happen).
enum DownloadPhase { case listing, downloading, compiling }

/// A download progress report.
struct DownloadProgress: Sendable {
    let fractionCompleted: Double
    let phase: DownloadPhase
}

/// Fetching the model files.
enum KokoroAneResourceDownloader {
    /// The model package's name: its folder, and its archive on sherpa-onnx's model releases.
    static let packageName = "kokoro-multi-lang-v1_0"
    /// Where the archive is downloaded from.
    static let packageURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(packageName).tar.bz2")!

    /// The cache folder holding the model (XDG cache): `~/.cache/papertalk`.
    static var modelsRoot: URL {
        let env = ProcessInfo.processInfo.environment
        let cache = env["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("papertalk", isDirectory: true)
    }

    /// The unpacked model package.
    static var modelDir: URL { modelsRoot.appendingPathComponent(packageName, isDirectory: true) }

    /// The package's files the engine loads.
    enum File: String, CaseIterable {
        case model = "model.onnx", voices = "voices.bin", tokens = "tokens.txt"
        case lexicon = "lexicon-us-en.txt", espeak = "espeak-ng-data"
    }

    /// A file of the unpacked package.
    static func path(_ file: File) -> String { modelDir.appendingPathComponent(file.rawValue).path }

    /// Whether every file the engine needs is there.
    static var modelsPresent: Bool { File.allCases.allSatisfy { FileManager.default.fileExists(atPath: path($0)) } }

    /// Downloads and unpacks the model if missing, reporting progress.
    @discardableResult
    static func ensureModels(variant: KokoroAneVariant = .english,
                             progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        if modelsPresent { return modelDir }
        progressHandler?(DownloadProgress(fractionCompleted: 0, phase: .listing))
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let archive = try await ModelDownload.fetch(packageURL) { fraction in
            progressHandler?(DownloadProgress(fractionCompleted: fraction, phase: .downloading))
        }
        defer { try? fm.removeItem(at: archive) }

        // Unpack beside the final folder, then move it in place, so an interrupted
        // unpack never looks like a complete model.
        let staging = modelsRoot.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try unpack(archive, into: staging)
        let unpacked = staging.appendingPathComponent(packageName, isDirectory: true)
        guard fm.fileExists(atPath: unpacked.appendingPathComponent(File.model.rawValue).path) else {
            throw KokoroLinuxError.badPackage
        }
        try? fm.removeItem(at: modelDir)
        try fm.moveItem(at: unpacked, to: modelDir)
        return modelDir
    }

    /// Extract a .tar.bz2 with the system's tar (bzip2 is on every desktop).
    private static func unpack(_ archive: URL, into folder: URL) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        tar.arguments = ["tar", "-xjf", archive.path, "-C", folder.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw KokoroLinuxError.unpackFailed }
    }
}

/// Why the Linux Kokoro engine couldn't run.
enum KokoroLinuxError: Error, LocalizedError {
    case downloadFailed(Int), badPackage, unpackFailed, loadFailed, unknownVoice(String), synthesisFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let status): return L("The Kokoro model couldn't be downloaded (HTTP {0}).", status)
        case .badPackage: return L("The downloaded Kokoro model is incomplete.")
        case .unpackFailed: return L("The Kokoro model couldn't be unpacked. Check that tar and bzip2 are installed.")
        case .loadFailed: return L("The Kokoro model couldn't be loaded.")
        case .unknownVoice(let voice): return L("Kokoro has no voice called “{0}”.", voice)
        case .synthesisFailed: return L("Kokoro couldn't voice this text.")
        }
    }
}

/// One file download with progress, through a URLSession delegate (the async
/// `download(from:)` reports none).
private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    /// Download `url` to a temporary file, reporting the fraction received.
    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ModelDownload(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns: move it first.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { finish(.failure(KokoroLinuxError.downloadFailed(status))); return }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("papertalk-kokoro-\(UUID().uuidString).tar.bz2")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    /// Resume the waiting caller once.
    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// The voice list.
enum KokoroAneConstants {
    /// Kokoro v1.0's voices, the same set as FluidAudio's English list, so a cast picked on
    /// macOS sounds the same here.
    static let englishVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky", "am_adam",
        "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
        "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex",
        "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro",
        "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni",
        "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    /// The model's speaker ids, in order (its `speaker_names` metadata): Kokoro's own order,
    /// with `em_santa` added last.
    static let speakerOrder: [String] = englishVoices.filter { $0 != "em_santa" } + ["em_santa"]

    /// The speaker id of a voice, nil for a voice the model doesn't have.
    static func speakerId(_ voice: String) -> Int32? {
        speakerOrder.firstIndex(of: voice).map(Int32.init)
    }
}

/// The one Kokoro instance, as on macOS. Model calls are blocking C calls, so they run on
/// one serial queue of their own (never the cooperative pool), which also keeps them strictly
/// one at a time.
actor KokoroEngine {
    /// The only instance.
    static let shared = KokoroEngine()

    /// Where every model call runs.
    private let queue = DispatchQueue(label: "papertalk.kokoro", qos: .userInitiated)
    /// The loaded model, once `prepare` has run.
    private var tts: Model?
    /// A load in progress, so overlapping `prepare` calls share it.
    private var loading: Task<Model, Error>?

    /// Load the model (downloads it first if needed). Safe to call repeatedly.
    func prepare() async throws {
        _ = try await model()
    }

    /// One piece of text as a 24 kHz mono 16-bit WAV.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        guard let sid = KokoroAneConstants.speakerId(voice) else { throw KokoroLinuxError.unknownVoice(voice) }
        let model = try await model()
        let (samples, rate) = try await onQueue { try model.generate(text, speaker: sid, speed: speed) }
        return SpeechAudio.wavFile(pcm16: SpeechAudio.resample(samples, from: Double(rate)))
    }

    /// The loaded model, loading it once.
    private func model() async throws -> Model {
        if let tts { return tts }
        if let loading { return try await loading.value }
        let task = Task { () throws -> Model in
            try await KokoroAneResourceDownloader.ensureModels()
            return try await self.onQueue { try Model() }
        }
        loading = task
        do {
            let model = try await task.value
            tts = model
            loading = nil
            return model
        } catch {
            loading = nil
            throw error
        }
    }

    /// Run blocking work on the engine's queue.
    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    /// The sherpa-onnx engine handle. Used only on the engine's queue.
    final class Model: @unchecked Sendable {
        private let handle: OpaquePointer

        /// Load the unpacked package (the US English lexicon, espeak-ng for unknown words).
        init() throws {
            let paths = KokoroAneResourceDownloader.self
            // The config holds C strings: keep copies alive until the engine is created.
            var owned: [UnsafeMutablePointer<CChar>] = []
            defer { owned.forEach { free($0) } }
            func c(_ s: String) -> UnsafePointer<CChar> {
                let p = strdup(s)!
                owned.append(p)
                return UnsafePointer(p)
            }
            var config = SherpaOnnxOfflineTtsConfig()
            config.model.kokoro.model = c(paths.path(.model))
            config.model.kokoro.voices = c(paths.path(.voices))
            config.model.kokoro.tokens = c(paths.path(.tokens))
            config.model.kokoro.data_dir = c(paths.path(.espeak))
            config.model.kokoro.lexicon = c(paths.path(.lexicon))
            config.model.kokoro.lang = c("en-us")
            config.model.kokoro.length_scale = 1
            config.model.num_threads = Int32(Self.threads)
            config.model.provider = c("cpu")
            config.model.debug = 0
            config.max_num_sentences = 1
            guard let handle = SherpaOnnxCreateOfflineTts(&config) else { throw KokoroLinuxError.loadFailed }
            self.handle = handle
        }

        deinit { SherpaOnnxDestroyOfflineTts(handle) }

        /// CPU threads for ONNX Runtime: most of the machine, leaving the UI a core.
        /// PAPERTALK_KOKORO_THREADS overrides it.
        static var threads: Int {
            if let value = ProcessInfo.processInfo.environment["PAPERTALK_KOKORO_THREADS"].flatMap(Int.init), value > 0 {
                return value
            }
            return max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        }

        /// `text` spoken by speaker `sid`: float samples in [-1, 1] and their rate.
        func generate(_ text: String, speaker sid: Int32, speed: Float) throws -> ([Float], Int) {
            var options = SherpaOnnxGenerationConfig()
            options.sid = sid
            options.speed = speed
            options.silence_scale = 0.2
            guard let audio = SherpaOnnxOfflineTtsGenerateWithConfig(handle, text, &options, nil, nil) else {
                throw KokoroLinuxError.synthesisFailed
            }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            let result = audio.pointee
            guard result.n > 0, let samples = result.samples else { return ([], Int(result.sample_rate)) }
            return (Array(UnsafeBufferPointer(start: samples, count: Int(result.n))), Int(result.sample_rate))
        }
    }
}
#endif
