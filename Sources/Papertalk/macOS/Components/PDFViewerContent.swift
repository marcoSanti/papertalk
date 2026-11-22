// The PDF viewer window's content (macOS): the pages as a strip of images over a title bar.

#if os(macOS)
import AppKit

/// The pages in a scroll view, with the title and Close under them.
final class PDFViewerContent: NSView {
    private let scroll: NSScrollView
    /// The width the pages are laid out for.
    private let openingWidth: CGFloat

    /// An empty viewer; `close` is sent to `target` by its Close button.
    init(frame: NSRect, title: String, target: AnyObject, close closeAction: Selector) {
        openingWidth = frame.width
        scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: frame.width, height: frame.height - 44))
        super.init(frame: frame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        // Show a lightweight placeholder immediately; pages arrive as they render.
        let busy = NSTextField(labelWithString: L("Rendering pages…"))
        busy.frame = NSRect(x: 0, y: 0, width: frame.width, height: 200)
        busy.alignment = .center
        busy.textColor = .secondaryLabelColor
        busy.font = .systemFont(ofSize: 14)
        busy.autoresizingMask = [.minXMargin, .maxXMargin]
        scroll.documentView = busy
        addSubview(scroll)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 44))
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 12, y: 13, width: frame.width - 140, height: 20)
        label.autoresizingMask = [.width]
        bar.addSubview(label)

        let close = NSButton(title: L("Close"), target: target, action: closeAction)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}" // Escape
        close.autoresizingMask = [.minXMargin]
        close.frame = NSRect(x: frame.width - 90, y: 9, width: 78, height: 26)
        bar.addSubview(close)

        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Render the pages in the background and show them when all are done.
    func render(_ data: Data) {
        let scroll = scroll, width = openingWidth
        // Render off the main thread (thread-safe CGContext drawing), then
        // assemble the page strip on the main thread when all pages are done.
        Task.detached(priority: .userInitiated) {
            guard let cg = Self.renderPagesCGRaw(from: data) else { return }
            let images = cg.map { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run {
                scroll.documentView = Self.makeContainer(images: images, width: width)
            }
        }
    }

    /// The pages stacked top to bottom, scaled to `width`.
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

    /// Renders every page to a CGImage at a capped width (2x for retina).
    /// CGContext-based, so it can run on a background thread.
    nonisolated static func renderPagesCGRaw(from data: Data, maxWidth: CGFloat = 900) -> [CGImage]? {
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
            guard let ctx = PageRaster.canvas(width: w, height: h, page: box.size) else { continue }
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            ctx.drawPDFPage(page)
            if let g = ctx.makeImage() { images.append(g) }
        }
        return images.isEmpty ? nil : images
    }
}

/// Container whose y origin is at the top, so pages stack downward naturally.
private final class FlippedView: NSView {
    /// Pages stack from the top, like a document.
    override var isFlipped: Bool { true }
}
#endif
