"""PDF text and cover images (PDFKit on macOS)."""
import io

import pypdfium2 as pdfium


def text(pdf: bytes) -> str:
    """All page text, pages separated by newlines. Empty for unreadable files,
    like PDFDocument returning nil on macOS."""
    try:
        doc = pdfium.PdfDocument(pdf)
    except pdfium.PdfiumError:
        return ""
    try:
        pages = []
        for page in doc:
            tp = page.get_textpage()
            pages.append(tp.get_text_range())
            tp.close()
            page.close()
        return "\n".join(pages)
    finally:
        doc.close()


def cover_png(pdf: bytes, width: float = 280) -> bytes:
    """The first page rendered to PNG, `width` pixels wide (empty if unreadable)."""
    try:
        doc = pdfium.PdfDocument(pdf)
    except pdfium.PdfiumError:
        return b""
    try:
        if len(doc) == 0:
            return b""
        page = doc[0]
        page_width, _ = page.get_size()
        image = page.render(scale=width / page_width).to_pil()
        page.close()
        out = io.BytesIO()
        image.save(out, format="PNG")
        return out.getvalue()
    finally:
        doc.close()
