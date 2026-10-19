import Foundation

/// Lets one holder through at a time; the rest wait in arrival order.
///
/// Voicing a paper holds Kokoro's buffers and the paper's audio in memory for
/// minutes. With several imports voicing at once (their calls interleaved in
/// `KokoroEngine`'s queue) small machines ran out of memory and crashed, so
/// `AppStore` voices whole papers one after another through this gate.
@MainActor
final class SerialGate {
    private var busy = false
    private var waiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []

    /// True while someone holds the gate.
    var isBusy: Bool { busy }
    /// How many callers are waiting for it.
    var waiting: Int { waiters.count }

    /// Wait for the gate. False when the caller's task was cancelled first:
    /// then it doesn't hold the gate and must not release it.
    @discardableResult
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard busy else { busy = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { @MainActor in self.dropWaiter(id) }
        }
    }

    /// Hand the gate to the next waiter (it stays busy), or free it.
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().cont.resume(returning: true) }
    }

    /// A cancelled waiter leaves the line without the gate.
    private func dropWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(returning: false)
    }
}
