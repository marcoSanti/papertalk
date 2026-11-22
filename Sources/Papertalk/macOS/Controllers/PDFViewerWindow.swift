// The PDF viewer window (macOS): pages rendered to images and stacked in a scroll view.

#if os(macOS)
import AppKit

/// Self-contained, resizable PDF viewer presented in its own window.
///
/// Renders pages to images with CoreGraphics directly (no PDFKit). PDFKit's
/// background Vision/OCR analysis crashes when the window closes mid-analysis,
/// so we avoid it entirely and reuse the same CG drawing the thumbnails use.
final class PDFViewerWindow: NSObject {
    private static var current: PDFViewerWindow?

    private var window: NSWindow?

    /// Open a viewer window for `data`.
    @discardableResult
    static func present(data: Data, title: String) -> PDFViewerWindow {
        let viewer = PDFViewerWindow()
        viewer.show(data: data, title: title)
        current = viewer
        return viewer
    }

    /// Show the window and render the pages in the background.
    func show(data: Data, title: String) {
        let contentRect = NSRect(x: 0, y: 0, width: 900, height: 680)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = title
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false // we own it; avoid double-release on close

        let content = PDFViewerContent(frame: contentRect, title: title, target: self, close: #selector(closeWindow))
        win.contentView = content
        window = win

        NotificationCenter.default.addObserver(self, selector: #selector(didClose),
                                               name: NSWindow.willCloseNotification, object: win)
        win.center()
        win.makeKeyAndOrderFront(nil)

        content.render(data)
    }

    /// ⌘W.
    @objc private func closeWindow() { window?.close() }

    /// Release the window controller once closed.
    @objc private func didClose() {
        NotificationCenter.default.removeObserver(self)
        window = nil
        PDFViewerWindow.current = nil
    }

}

#endif
