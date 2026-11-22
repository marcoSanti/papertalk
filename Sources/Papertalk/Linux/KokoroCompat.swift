// Linux stand-ins for FluidAudio's Kokoro API and the macOS `KokoroEngine`, backed by
// kokoro-onnx through Python.

#if os(Linux)
import Foundation
import PythonKit

// Kokoro on Linux: kokoro-onnx on the CPU (python/papertalk_platform/tts.py),
// behind the same API the shared code uses from FluidAudio and the macOS
// KokoroEngine, so AppStore, PlayerController and Kokoro.swift are unchanged.

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
    /// Where tts.py keeps the model files (XDG cache, like the Python side).
    static var modelsRoot: URL {
        let env = ProcessInfo.processInfo.environment
        let cache = env["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("papertalk", isDirectory: true)
    }

    /// Downloads the ONNX model and voices if missing, reporting progress.
    @discardableResult
    static func ensureModels(variant: KokoroAneVariant = .english,
                             progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        try await PythonRuntime.shared.run {
            let tts = PythonRuntime.shared.module("tts")
            guard !Bool(tts.models_present())! else { return }
            progressHandler?(DownloadProgress(fractionCompleted: 0, phase: .listing))
            let report = PythonFunction { args in
                let fraction = Double(args[0]) ?? 0
                progressHandler?(DownloadProgress(fractionCompleted: fraction, phase: .downloading))
                return Python.None
            }
            tts.download_models(report)
        }
        return modelsRoot.appendingPathComponent("kokoro", isDirectory: true)
    }
}

/// The voice list.
enum KokoroAneConstants {
    /// Kokoro v1.0's voices, the same set as FluidAudio's English list (and as
    /// voices-v1.0.bin), so a cast picked on macOS sounds the same here.
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
}

/// The one Kokoro instance, as on macOS. Calls are already serialised by the
/// single Python thread, so there's no queue here.
actor KokoroEngine {
    /// The only instance.
    static let shared = KokoroEngine()

    /// Load the model (downloads it first if needed). Safe to call repeatedly.
    func prepare() async throws {
        try await PythonRuntime.shared.run { _ = PythonRuntime.shared.module("tts").prepare() }
    }

    /// `text` spoken by `voice` as 24 kHz mono 16-bit WAV.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await PythonRuntime.shared.run {
            Data(python: PythonRuntime.shared.module("tts").synthesize(text, voice, Double(speed)))
        }
    }
}
#endif
