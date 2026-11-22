"""Shared pytest set-up: the package on sys.path, and a tiny PDF builder."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "linux-dev"))

from pdf_fixture import one_page_pdf


def make_pdf(text: str = "Hello Papertalk") -> bytes:
    """A minimal one-page PDF with `text` in Helvetica, built by hand."""
    return one_page_pdf(f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode())
