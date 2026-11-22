// Tests of `SerialGate`.

import XCTest
@testable import Papertalk

/// The gate that keeps audio baking to one paper at a time.
@MainActor
final class SerialGateTests: PapertalkTestCase {
    func testOneHolderAtATimeInArrivalOrder() async {
        let gate = SerialGate()
        var inside = 0, maxInside = 0
        var order: [Int] = []

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask { @MainActor in
                    await gate.acquire()
                    inside += 1; maxInside = max(maxInside, inside); order.append(i)
                    // Suspend while holding, as a bake does between turns.
                    for _ in 0..<5 { await Task.yield() }
                    inside -= 1
                    gate.release()
                }
                // Let each task queue up before adding the next, so arrival order is known.
                for _ in 0..<3 { await Task.yield() }
            }
        }

        XCTAssertEqual(maxInside, 1)
        XCTAssertEqual(order, [0, 1, 2, 3])
        XCTAssertFalse(gate.isBusy)
        XCTAssertEqual(gate.waiting, 0)
    }

    func testReleaseWithoutWaitersFreesTheGate() async {
        let gate = SerialGate()
        await gate.acquire()
        XCTAssertTrue(gate.isBusy)
        gate.release()
        XCTAssertFalse(gate.isBusy)
        await gate.acquire()  // free again: doesn't hang
        XCTAssertTrue(gate.isBusy)
    }

    /// A paper stopped while it waits for another's audio leaves the line
    /// without the gate, and the gate still goes to the next in line.
    func testCancelledWaiterLeavesWithoutTheGate() async {
        let gate = SerialGate()
        await gate.acquire()
        let cancelled = Task { @MainActor in await gate.acquire() }
        let next = Task { @MainActor in await gate.acquire() }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(gate.waiting, 2)
        cancelled.cancel()
        let gotIt = await cancelled.value
        XCTAssertFalse(gotIt)
        XCTAssertEqual(gate.waiting, 1)
        gate.release()
        let nextGotIt = await next.value
        XCTAssertTrue(nextGotIt)
        XCTAssertTrue(gate.isBusy)
        gate.release()
        XCTAssertFalse(gate.isBusy)
    }

    func testAlreadyCancelledCallerDoesNotTakeAFreeGate() async {
        let gate = SerialGate()
        let t = Task { @MainActor () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.acquire()
        }
        let got = await t.value
        XCTAssertFalse(got)
        XCTAssertFalse(gate.isBusy)
    }

    func testStoreSharesOneGate() async {
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()))
        XCTAssertFalse(store.audioGate.isBusy)
        XCTAssertFalse(store.importGate.isBusy)
    }

    /// Imports started together go through the pipeline one at a time, in the order they were
    /// started: the second stays queued (no LLM call) until the first leaves the queue.
    func testImportsQueueInOrder() async {
        let storage = LocalStorage(root: Fixtures.tempDir())
        await storage.save(Fixtures.paper(id: "seed"), K.paper("seed"))
        let store = AppStore(storage: storage, speech: FakeSpeechBackend())
        await waitUntil { store.papers["seed"] != nil }
        store.llm.baseUrl = "http://mock.local/v1"
        MockLLM.install { _ in (200, MockLLM.chatReply("{}")) }

        let pdf = Fixtures.pdf(lines: ["Some paper text"])
        for name in ["queue-1.pdf", "queue-2.pdf", "queue-3.pdf"] { store.upload(pdf, filename: name, depth: .summary, depthNote: "") }
        func paper(_ name: String) -> Paper? { store.papers.values.first { $0.filename == name } }

        for name in ["queue-1.pdf", "queue-2.pdf", "queue-3.pdf"] {
            await waitUntil { store.pendingCast != nil }
            XCTAssertEqual(store.pendingCast?.paperId, paper(name)?.id)
            for later in ["queue-1.pdf", "queue-2.pdf", "queue-3.pdf"].drop(while: { $0 != name }).dropFirst() {
                XCTAssertEqual(paper(later)?.state, "queued")
            }
            store.cancelCast()
        }
        await waitUntil { !store.importGate.isBusy }
        XCTAssertEqual(store.papers.count, 1)
    }
}
