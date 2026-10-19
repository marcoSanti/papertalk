#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Papertalk

/// Lays the real Settings sheet out in an offscreen window and checks that its
/// sidebar of pages can be seen whichever page it opens on. Clear Data once
/// stretched the sidebar's table thousands of points tall and scrolled it to
/// the bottom, so the sidebar looked empty (and Voices couldn't be reached).
@MainActor
final class SettingsLayoutTests: PapertalkTestCase {
    func testSidebarIsVisibleOnEveryPage() async throws {
        _ = NSApplication.shared
        // The LLM page is left out: opening it asks the configured endpoint for models.
        for page: AppStore.SettingsPage in [.clear, .voices, .server, .prompts, .presets] {
            let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()), speech: FakeSpeechBackend())
            store.settingsPage = page
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store))
            window.orderFrontRegardless()
            defer { window.close() }

            var sidebar: NSTableView?
            await waitUntil(timeout: 5) {
                sidebar = Self.tables(in: window.contentView!).first
                return (sidebar?.numberOfRows ?? 0) > 0
            }
            try? await Task.sleep(nanoseconds: 300_000_000)   // let the split view settle
            let table = try XCTUnwrap(sidebar, "\(page)")
            XCTAssertEqual(table.numberOfRows, 6, "\(page)")
            XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: 0)), "first page hidden when opening \(page)")
            XCTAssertLessThan(table.frame.height, 1000, "sidebar stretched when opening \(page)")
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables(in: $0) }
    }
}
#endif
