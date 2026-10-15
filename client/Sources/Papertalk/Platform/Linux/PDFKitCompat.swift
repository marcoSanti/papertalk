#if os(Linux)
import Foundation
import PythonKit

// PDFKit's PDFDocument/PDFPage as far as Pipeline.extractText uses them,
// backed by pypdfium2 (python/papertalk_platform/pdf.py).

final class PDFDocument {
    private let texts: [String]

    /// nil for data that isn't a readable PDF, like PDFKit.
    init?(data: Data) {
        let pages = try? PythonRuntime.shared.runSync { () -> [String]? in
            let result = PythonRuntime.shared.module("pdf").pages(data.python)
            return result == Python.None ? nil : result.map { String($0) ?? "" }
        }
        guard let pages = pages ?? nil else { return nil }
        texts = pages
    }

    var pageCount: Int { texts.count }

    func page(at index: Int) -> PDFPage? {
        texts.indices.contains(index) ? PDFPage(string: texts[index]) : nil
    }

    /// The first page as PNG, `width` pixels wide (the cover in the library).
    static func coverPNG(of data: Data, width: Double) -> Data? {
        let png = try? PythonRuntime.shared.runSync {
            Data(python: PythonRuntime.shared.module("pdf").cover_png(data.python, width))
        }
        return png?.isEmpty == false ? png : nil
    }
}

final class PDFPage {
    let string: String?
    init(string: String?) { self.string = string }
}
#endif
