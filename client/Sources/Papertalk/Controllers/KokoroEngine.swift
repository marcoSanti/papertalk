import Foundation
import FluidAudio

/// The one Kokoro model instance in the app, shared by import-time baking,
/// live playback and voice samples.
///
/// Calls run strictly one at a time. `KokoroAneManager` is an actor, but
/// actors are re-entrant across `await`s, so overlapping callers could still
/// drive the Core ML chain concurrently — and two separate managers would load
/// the model twice onto the Neural Engine. Both have been seen to fail with
/// "unable to compute the asynchronous prediction". A failed prediction is
/// retried, the last attempt on a freshly loaded model.
actor KokoroEngine {
    static let shared = KokoroEngine()

    private var manager = KokoroAneManager(variant: .english)
    private var initialized = false
    /// Tail of the queue: each call waits for the previous one to finish.
    private var tail: Task<Void, Never>?

    /// Load the model (downloads it first if needed). Safe to call repeatedly.
    func prepare() async throws {
        try await enqueue { try await self.ensureInitialized() }
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await enqueue { try await self.synthesizeWithRetry(text: text, voice: voice, speed: speed) }
    }

    // MARK: - Queue

    private func enqueue<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    // MARK: - Work (only ever one at a time, via the queue)

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        try await manager.initialize()
        initialized = true
    }

    private func synthesizeWithRetry(text: String, voice: String, speed: Float) async throws -> Data {
        let attempts = 3
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                try await ensureInitialized()
                return try await manager.synthesize(text: text, voice: voice, speed: speed)
            } catch {
                lastError = error
                if Task.isCancelled { throw error }
                // Give the Neural Engine a moment; before the final attempt,
                // drop the model and load it again from scratch.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                if attempt == attempts - 1 {
                    manager = KokoroAneManager(variant: .english)
                    initialized = false
                }
            }
        }
        throw lastError ?? CancellationError()
    }
}
