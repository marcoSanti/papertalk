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
        let contentRect = NSRect(x: 0, y: 0, width: 900, height: 680)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = title
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false // we own it; avoid double-release on close

        let content = NSView(frame: contentRect)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: contentRect.width, height: contentRect.height - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        // Show a lightweight placeholder immediately; pages arrive as they render.
        let busy = NSTextField(labelWithString: "Rendering pages…")
        busy.frame = NSRect(x: 0, y: 0, width: contentRect.width, height: 200)
        busy.alignment = .center
        busy.textColor = .secondaryLabelColor
        busy.font = .systemFont(ofSize: 14)
        busy.autoresizingMask = [.minXMargin, .maxXMargin]
        scroll.documentView = busy
        content.addSubview(scroll)

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

        // Render off the main thread (thread-safe CGContext drawing), then
        // assemble the page strip on the main thread when all pages are done.
        Task.detached(priority: .userInitiated) {
            guard let cg = Self.renderPagesCGRaw(from: data) else { return }
            let images = cg.map { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run {
                scroll.documentView = Self.makeContainer(images: images, width: contentRect.width)
            }
        }
    }

    private static func makeContainer(images: [NSImage], width: CGFloat) -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 12))
        container.autoresizingMask = [.width]
        let pageWidth: CGFloat = 720
        var y: CGFloat = 12
        for img in images {
            let h = pageWidth * img.size.height / img.size.width
            let iv = NSImageView(frame: NSRect(x: container.bounds.width / 2 - pageWidth/2, y: y, width: pageWidth, height: h))
            iv.image = img
            iv.imageScaling = .scaleAxesIndependently
            iv.autoresizingMask = [.minXMargin, .maxXMargin] // keep centered horizontally
            container.addSubview(iv)
            y += h + 14
        }
        container.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
        return container
    }

    @objc private func closeWindow() { window?.close() }

    @objc private func didClose() {
        NotificationCenter.default.removeObserver(self)
        window = nil
        PDFViewerWindow.current = nil
    }

    /// Renders every page to a CGImage at a capped width (2x for retina).
    /// CGContext-based, so it can run on a background thread.
    static func renderPagesCGRaw(from data: Data, maxWidth: CGFloat = 900) -> [CGImage]? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else { return nil }
        let scale: CGFloat = 2
        var images: [CGImage] = []
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { continue }
            let w = maxWidth * scale
            let h = w * box.height / box.width
            guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: w / box.width, y: h / box.height)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            ctx.drawPDFPage(page)
            if let g = ctx.makeImage() { images.append(g) }
        }
        return images.isEmpty ? nil : images
    }
}

/// Container whose y origin is at the top, so pages stack downward naturally.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}