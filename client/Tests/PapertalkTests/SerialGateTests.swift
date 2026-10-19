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

    func testStoreSharesOneGate() async {
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()))
        XCTAssertFalse(store.audioGate.isBusy)
    }
}
