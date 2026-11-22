// Tests of a paper's own window on macOS.

#if os(macOS)
import AppKit
import XCTest
@testable import Papertalk

/// The paper window: one per paper, titled with the paper, gone when the paper is.
@MainActor
final class PaperWindowTests: PapertalkTestCase {
    private func windows(_ title: String) -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && $0.title == title }
    }

    func testOneWindowPerPaperThatClosesWhenThePaperIsDeleted() async throws {
        _ = NSApplication.shared
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()), speech: FakeSpeechBackend())
        store.papers["pw"] = Fixtures.paper(id: "pw", title: "Paper window test", state: "queued")
        PaperWindow.present(paperId: "pw", store: store)
        await waitUntil { !self.windows("Paper window test").isEmpty }
        let win = try XCTUnwrap(windows("Paper window test").first)
        XCTAssertTrue(win.styleMask.contains(.resizable))

        PaperWindow.present(paperId: "pw", store: store)
        XCTAssertEqual(windows("Paper window test").count, 1)

        store.papers["pw"] = nil
        await waitUntil { self.windows("Paper window test").isEmpty }
        XCTAssertTrue(windows("Paper window test").isEmpty)
    }
}
#endif
