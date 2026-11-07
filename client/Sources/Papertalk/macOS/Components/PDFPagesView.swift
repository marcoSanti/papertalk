// The Ask window's paper pane (macOS): the PDF's pages in an AppKit scroll view, a quote marked.

#if os(macOS)
import AppKit
import SwiftUI

/// The paper's pages top to bottom, fitted to the pane's width, with `found`'s lines highlighted.
/// AppKit, not a SwiftUI stack: each page draws its PDF page only when it's on screen (no page
/// images held in memory), and page offsets are exact, so a jump lands on the quote.
struct PDFPagesView: NSViewRepresentable {
    let pdf: Data
    /// The page (from 1) and lines (fractions of the page, top-left origin) to mark.
    let found: (page: Int, rects: [CGRect])?
    /// Changes whenever the pane should scroll to `found`.
    let revealToken: Int

    /// The last reveal done, so a SwiftUI update that isn't a new one doesn't scroll.
    final class Coordinator { var revealed: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PagesScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.documentView = PagesDocumentView(pdf: pdf)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let doc = scroll.documentView as? PagesDocumentView else { return }
        doc.mark(page: found?.page, rects: found?.rects ?? [])
        if let found, context.coordinator.revealed != revealToken {
            context.coordinator.revealed = revealToken
            doc.reveal(page: found.page, y: found.rects.map(\.minY).min() ?? 0)
        }
    }
}

/// Refits the pages whenever the pane's width changes.
private final class PagesScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? PagesDocumentView)?.fit(width: contentView.bounds.width)
    }
}

/// The pages stacked from the top, and the pending scroll to a quote.
private final class PagesDocumentView: NSView {
    private let pages: [PageView]
    private var fittedWidth: CGFloat = 0
    /// A scroll asked for before the pages were laid out.
    private var pendingReveal: (page: Int, y: CGFloat)?
    private static let gap: CGFloat = 12

    init(pdf: Data) {
        let doc = CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init)
        pages = (0..<(doc?.numberOfPages ?? 0)).map { PageView(page: doc?.page(at: $0 + 1)) }
        super.init(frame: .zero)
        pages.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    /// Lay the pages out at `width`, keeping the reader's place.
    func fit(width: CGFloat) {
        guard width > 0, width != fittedWidth else { return }
        let scroll = enclosingScrollView
        let oldHeight = max(frame.height, 1)
        let oldY = scroll?.contentView.bounds.minY ?? 0
        fittedWidth = width
        let pageWidth = max(width - 2 * Self.gap, 50)
        var y = Self.gap
        for p in pages {
            let h = pageWidth * p.aspect
            p.frame = NSRect(x: Self.gap, y: y, width: pageWidth, height: h)
            p.needsDisplay = true
            y += h + Self.gap
        }
        setFrameSize(NSSize(width: width, height: y))
        if let scroll, oldY > 0 { scrollTo(oldY / oldHeight * y, in: scroll, animated: false) }
        if let r = pendingReveal { pendingReveal = nil; reveal(page: r.page, y: r.y) }
    }

    /// Highlight `rects` on `page` (from 1) and clear every other page.
    func mark(page: Int?, rects: [CGRect]) {
        for (i, p) in pages.enumerated() { p.highlights = i + 1 == page ? rects : [] }
    }

    /// Scroll so the point `y` (a fraction down `page`) sits a third of the way down the pane.
    func reveal(page: Int, y: CGFloat) {
        guard let scroll = enclosingScrollView, fittedWidth > 0, pages.indices.contains(page - 1) else {
            pendingReveal = (page, y)
            return
        }
        let p = pages[page - 1].frame
        scrollTo(p.minY + y * p.height - scroll.contentView.bounds.height / 3, in: scroll, animated: true)
    }

    private func scrollTo(_ y: CGFloat, in scroll: NSScrollView, animated: Bool) {
        let top = max(0, min(y, frame.height - scroll.contentView.bounds.height))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: top))
            }
        } else {
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: top))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// One PDF page, drawn straight from the PDF when AppKit needs it, with its highlights on top.
private final class PageView: NSView {
    private let page: CGPDFPage?
    private let box: CGRect
    /// Lines to mark, as fractions of the page with the origin at the top left.
    var highlights: [CGRect] = [] { didSet { if highlights != oldValue { needsDisplay = true } } }
    /// Height over width.
    var aspect: CGFloat { box.width > 0 ? box.height / box.width : 1.294 }

    init(page: CGPDFPage?) {
        self.page = page
        box = page?.getBoxRect(.mediaBox) ?? .zero
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawConcurrently = true   // drawing a dense page off the main thread keeps the window responsive
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(.white)
        ctx.fill(bounds)
        if let page, box.width > 0, box.height > 0 {
            ctx.saveGState()
            // PDF space has its origin at the bottom left; this view's is at the top.
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: bounds.width / box.width, y: -bounds.height / box.height)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard !highlights.isEmpty else { return }
        let accent = NSColor(Color.appAccent)
        for r in highlights {
            let rect = NSRect(x: r.minX * bounds.width - 2, y: r.minY * bounds.height - 1.5,
                              width: r.width * bounds.width + 4, height: r.height * bounds.height + 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            NSColor.systemYellow.withAlphaComponent(0.4).setFill()
            path.fill()
            accent.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }
        let top = highlights.map(\.minY).min()! * bounds.height, bottom = highlights.map(\.maxY).max()! * bounds.height
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: top - 3, width: 4, height: bottom - top + 6), xRadius: 2, yRadius: 2).fill()
    }
}
#endif
