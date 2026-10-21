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
}
#endif
