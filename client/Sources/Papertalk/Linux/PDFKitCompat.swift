// Linux stand-in for PDFKit: page text and the cover image of a PDF, through poppler-glib
// and cairo.

#if os(Linux)
import CPoppler
import Foundation

// PDFKit's PDFDocument/PDFPage as far as the shared code uses them (Pipeline.extractText,
// the library covers). Calls take one lock: poppler's rendering (its font set-up in
// particular) crashed when several covers were drawn on different threads at once.

/// A PDF's pages as text (only what `LocalPipeline.extractText` needs).
final class PDFDocument {
    private let texts: [String]

    /// nil for data that isn't a readable PDF, like PDFKit.
    init?(data: Data) {
        guard let pages = Poppler.withDocument(data, { doc in
            (0..<poppler_document_get_n_pages(doc)).map { index -> String in
                guard let page = poppler_document_get_page(doc, index) else { return "" }
                defer { g_object_unref(UnsafeMutableRawPointer(page)) }
                guard let text = poppler_page_get_text(page) else { return "" }
                defer { g_free(text) }
                return String(cString: text)
            }
        }) else { return nil }
        texts = pages
    }

    /// Pages in the document.
    var pageCount: Int { texts.count }

    /// The page at `index`, nil out of range.
    func page(at index: Int) -> PDFPage? {
        texts.indices.contains(index) ? PDFPage(string: texts[index]) : nil
    }

    /// The first page as PNG, `width` pixels wide (the cover in the library).
    static func coverPNG(of data: Data, width: Double) -> Data? {
        Poppler.withDocument(data) { doc -> Data? in
            guard poppler_document_get_n_pages(doc) > 0, let page = poppler_document_get_page(doc, 0) else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(page)) }
            return Poppler.png(of: page, width: width)
        } ?? nil
    }
}

/// A page: just its text.
final class PDFPage {
    /// The page's extracted text.
    let string: String?
    init(string: String?) { self.string = string }
}

/// The poppler calls behind `PDFDocument`.
enum Poppler {
    /// Held for every document, so poppler only ever runs on one thread at a time.
    private static let lock = NSLock()

    /// Open `data` as a PDF and run `body` on it; nil when it isn't a readable PDF.
    static func withDocument<T>(_ data: Data, _ body: (OpaquePointer) -> T) -> T? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        guard let doc = poppler_document_new_from_bytes(bytes, nil, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        defer { g_object_unref(UnsafeMutableRawPointer(doc)) }
        return body(doc)
    }

    /// `page` rendered on white, `width` pixels wide, as PNG bytes.
    static func png(of page: OpaquePointer, width: Double) -> Data? {
        var pageWidth = 0.0, pageHeight = 0.0
        poppler_page_get_size(page, &pageWidth, &pageHeight)
        guard pageWidth > 0, pageHeight > 0, width > 0 else { return nil }
        let scale = width / pageWidth
        let pixelsWide = Int32(width.rounded()), pixelsHigh = Int32((pageHeight * scale).rounded())
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_RGB24, pixelsWide, pixelsHigh) else { return nil }
        defer { cairo_surface_destroy(surface) }
        guard let cr = cairo_create(surface) else { return nil }
        cairo_set_source_rgb(cr, 1, 1, 1)
        cairo_paint(cr)
        cairo_scale(cr, scale, scale)
        poppler_page_render(page, cr)
        cairo_destroy(cr)
        cairo_surface_flush(surface)

        // cairo writes the PNG through a C callback: collect it into a box passed as the closure.
        final class Sink { var data = Data() }
        let sink = Sink()
        let status = cairo_surface_write_to_png_stream(surface, { closure, bytes, length in
            guard let closure, let bytes else { return CAIRO_STATUS_WRITE_ERROR }
            Unmanaged<Sink>.fromOpaque(closure).takeUnretainedValue().data.append(bytes, count: Int(length))
            return CAIRO_STATUS_SUCCESS
        }, Unmanaged.passUnretained(sink).toOpaque())
        return status == CAIRO_STATUS_SUCCESS && !sink.data.isEmpty ? sink.data : nil
    }
}
#endif
