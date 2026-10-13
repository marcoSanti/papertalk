import AppKit

/// Self-contained, resizable PDF viewer presented in its own window.
///
/// Renders pages to images with CoreGraphics directly (no PDFKit). PDFKit's
/// background Vision/OCR analysis crashes when the window closes mid-analysis,
/// so we avoid it entirely and reuse the same CG drawing the thumbnails use.
final class PDFViewerWindow: NSObject {
    private static var current: PDFViewerWindow?

    private var window: NSWindow?

    @discardableResult
    static func present(data: Data, title: String) -> PDFViewerWindow {
        let viewer = PDFViewerWindow()
        viewer.show(data: data, title: title)
        current = viewer
        return viewer
    }

    func show(data: Data, title: String) {
        guard let pages = Self.renderPages(from: data), !pages.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Could not render this PDF"
            alert.informativeText = "The paper could not be opened."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let contentRect = NSRect(x: 0, y: 0, width: 900, height: 680)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = title
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false // we own it; avoid double-release on close

        let content = NSView(frame: contentRect)

        // Scroll view holding the rendered pages.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: contentRect.width, height: contentRect.height - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let container = FlippedView(frame: NSZeroRect)
        container.autoresizingMask = [.width]
        let pageWidth: CGFloat = 720
        var y: CGFloat = 12
        for img in pages {
            let h = pageWidth * img.size.height / img.size.width
            let iv = NSImageView(frame: NSRect(x: container.bounds.width / 2 - pageWidth/2, y: y, width: pageWidth, height: h))
            iv.image = img
            iv.imageScaling = .scaleAxesIndependently
            iv.autoresizingMask = [.minXMargin, .maxXMargin] // keep centered horizontally
            container.addSubview(iv)
            y += h + 14
        }
        container.frame = NSRect(x: 0, y: 0, width: contentRect.width, height: y + 8)
        scroll.documentView = container
        content.addSubview(scroll)

        // Bottom bar: title left, Close right.
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: 44))
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 12, y: 13, width: contentRect.width - 140, height: 20)
        label.autoresizingMask = [.width]
        bar.addSubview(label)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}" // Escape
        close.autoresizingMask = [.minXMargin]
        close.frame = NSRect(x: contentRect.width - 90, y: 9, width: 78, height: 26)
        bar.addSubview(close)

        content.addSubview(bar)
        win.contentView = content
        window = win

        NotificationCenter.default.addObserver(self, selector: #selector(didClose),
                                               name: NSWindow.willCloseNotification, object: win)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func closeWindow() { window?.close() }

    @objc private func didClose() {
        NotificationCenter.default.removeObserver(self)
        window = nil
        PDFViewerWindow.current = nil
    }

    /// Renders every page to an NSImage at a capped width (2x for retina).
    static func renderPages(from data: Data, maxWidth: CGFloat = 900) -> [NSImage]? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else { return nil }
        let scale: CGFloat = 2
        var images: [NSImage] = []
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { continue }
            let imgWidth = maxWidth * scale
            let imgHeight = imgWidth * box.height / box.width
            let size = NSSize(width: imgWidth, height: imgHeight)
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: size).fill()
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.scaleBy(x: imgWidth / box.width, y: imgHeight / box.height)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            img.unlockFocus()
            images.append(img)
        }
        return images.isEmpty ? nil : images
    }
}

/// Container whose y origin is at the top, so pages stack downward naturally.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}