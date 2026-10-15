"""PDF text and cover images (PDFKit on macOS)."""
import io

import pypdfium2 as pdfium


def pages(pdf: bytes):
    """The text of each page, or None for an unreadable file (like PDFDocument
    returning nil on macOS)."""
    try:
        doc = pdfium.PdfDocument(pdf)
    except pdfium.PdfiumError:
        return None
    try:
        out = []
        for page in doc:
            tp = page.get_textpage()
            out.append(tp.get_text_range())
            tp.close()
            page.close()
        return out
    finally:
        doc.close()


def text(pdf: bytes) -> str:
    """All page text, pages separated by newlines. Empty for unreadable files."""
    return "\n".join(pages(pdf) or [])


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
