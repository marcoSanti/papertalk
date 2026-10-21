// Tests of the mind map's window on macOS.

#if os(macOS)
import AppKit
import XCTest
@testable import Papertalk

/// The mind map opens in a window of its own that can be closed, resized and
/// maximised but not minimised, one per paper.
@MainActor
final class MindMapWindowTests: PapertalkTestCase {
    private func windows(_ title: String) -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && $0.title.hasSuffix(title) }
    }

    func testOpensOneClosableResizableWindowPerPaperWithoutMinimise() async throws {
        _ = NSApplication.shared
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply()))
        MindMapWindow.present(map: map, title: "Window test paper", paperId: "w1")
        let win = try XCTUnwrap(windows("Window test paper").first)
        defer { win.close() }
        XCTAssertEqual(win.title, "Mind map — Window test paper")
        XCTAssertTrue(win.styleMask.contains(.closable))
        XCTAssertTrue(win.styleMask.contains(.resizable))
        XCTAssertFalse(win.styleMask.contains(.miniaturizable))
        XCTAssertTrue(win.collectionBehavior.contains(.fullScreenNone))      // green button maximises
        XCTAssertNotNil(win.standardWindowButton(.zoomButton))
        XCTAssertFalse(win.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false)

        // Opening it again reuses the window.
        MindMapWindow.present(map: map, title: "Window test paper", paperId: "w1")
        XCTAssertEqual(windows("Window test paper").count, 1)

        win.performClose(nil)
        XCTAssertTrue(windows("Window test paper").isEmpty)
        // Closed windows are forgotten: the next open makes a fresh one.
        MindMapWindow.present(map: map, title: "Window test paper", paperId: "w1")
        let again = try XCTUnwrap(windows("Window test paper").first)
        XCTAssertFalse(again === win)
        again.close()
    }

    func testAConnectedMapReplacesTheOneInTheSameWindow() async throws {
        _ = NSApplication.shared
        let storage = LocalStorage(root: Fixtures.tempDir())
        let map = try XCTUnwrap(MindMap.parse(MindMapFixtures.reply()))
        for (id, title) in [("sa", "Swap paper A"), ("sb", "Swap paper B")] {
            var p = Fixtures.paper(id: id, title: title)
            p.hasMindMap = true
            await storage.save(p, K.paper(id))
            await storage.save(map, K.mindMap(id))
        }
        let store = AppStore(storage: storage, speech: FakeSpeechBackend())
        await waitUntil { store.papers.count == 2 }

        MindMapWindow.open(paperId: "sa", store: store)
        await waitUntil { !self.windows("Swap paper A").isEmpty }
        let win = try XCTUnwrap(windows("Swap paper A").first)
        defer { win.close() }

        MindMapWindow.openConnected("sb", from: "sa", store: store)
        await waitUntil { win.title.hasSuffix("Swap paper B") }
        XCTAssertEqual(win.title, "Mind map — Swap paper B")
        XCTAssertEqual(windows("Swap paper B").count, 1, "no second window")
        await waitUntil { (win.contentView?.alphaValue ?? 0) > 0.99 }
        XCTAssertEqual(win.contentView?.alphaValue ?? 0, 1, accuracy: 0.01, "faded back in")

        // A is free again: opening it makes its own window; B stays where it is.
        MindMapWindow.open(paperId: "sa", store: store)
        await waitUntil { !self.windows("Swap paper A").isEmpty }
        let other = try XCTUnwrap(windows("Swap paper A").first)
        XCTAssertFalse(other === win)
        other.close()
        // Opening B again from anywhere brings this window forward rather than swapping.
        MindMapWindow.openConnected("sb", from: "sa", store: store)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(windows("Swap paper B").count, 1)
    }
}
#endif
