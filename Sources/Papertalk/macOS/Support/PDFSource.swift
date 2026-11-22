// Ask's paper pane (macOS): where a cited quote sits in the PDF.

#if os(macOS)
import AppKit
import PDFKit

/// Finding a citation's quote for the Ask window's paper pane. Searches with `PDFDocument` only,
/// never a `PDFView`: its background text analysis crashes when a window closes mid-analysis.
enum PDFSource {
    /// Where a citation's quote is: the page it's on (from 1) and one rect per line as fractions
    /// of the page with the origin at the top left; nil if not found. The whole quote is looked
    /// for first on the cited page, then the pages either side (models miscount by one), before
    /// its shorter openings (`PaperChat.searchStrings`), which can match the wrong place; then
    /// the rest of the paper.
    // shortcut: assumes unrotated pages (mediaBox, like the renderer); rotate the rects if rotated PDFs show up off.
    static func find(_ c: PaperChat.Citation, in pdf: Data) -> (page: Int, rects: [CGRect])? {
        guard let doc = PDFDocument(data: pdf), doc.pageCount > 0 else { return nil }
        let near = [c.page, c.page - 1, c.page + 1].filter { $0 >= 1 && $0 <= doc.pageCount }
        let rest = (1...doc.pageCount).filter { !near.contains($0) }
        for pages in [near, rest] {
            for s in PaperChat.searchStrings(c.quote) {
                for n in pages {
                    if let rects = rects(of: s, on: n, in: doc) { return (n, rects) }
                }
            }
        }
        return nil
    }

    /// The lines of `s` on page `n` (from 1), as fractions of the page; nil if it isn't there.
    private static func rects(of s: String, on n: Int, in doc: PDFDocument) -> [CGRect]? {
        guard let p = doc.page(at: n - 1), let text = p.string,
              let range = PaperChat.locate(s, in: text), let sel = p.selection(for: range) else { return nil }
        let box = p.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rects = sel.selectionsByLine().map { (line: PDFSelection) -> CGRect in
            let r = line.bounds(for: p)
            return CGRect(x: (r.minX - box.minX) / box.width, y: (box.maxY - r.maxY) / box.height,
                          width: r.width / box.width, height: r.height / box.height)
        }.filter { $0.width > 0 && $0.height > 0 }
        return rects.isEmpty ? nil : rects
    }
}
#endif
