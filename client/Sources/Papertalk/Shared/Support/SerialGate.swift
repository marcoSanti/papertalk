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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True while someone holds the gate.
    var isBusy: Bool { busy }
    /// How many callers are waiting for it.
    var waiting: Int { waiters.count }

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hand the gate to the next waiter (it stays busy), or free it.
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
