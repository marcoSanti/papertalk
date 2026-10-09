"""PDF -> structured Paper (title, abstract, sections, captions) using PyMuPDF.

Heuristics, in order of reliability:
  1. Running headers/footers (lines repeated across many pages) are dropped.
  2. Body font size = the most common span size weighted by characters.
  3. A line is a heading if it is short and either matches a known section name /
     numbered pattern, or is noticeably larger than body text, or is bold + numbered.
If no headings are found, pages become pseudo-sections so downstream code still works.
Math is extracted as whatever Unicode the PDF contains; the LLM is told to verbalise it.
"""
from __future__ import annotations

import re
import unicodedata
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import pymupdf

KNOWN_SECTIONS = (
    "abstract", "introduction", "background", "related work", "related works",
    "preliminaries", "method", "methods", "methodology", "approach", "model",
    "materials and methods", "experimental setup", "experiments", "experimental results",
    "results", "results and discussion", "evaluation", "analysis", "discussion",
    "limitations", "future work", "conclusion", "conclusions", "concluding remarks",
    "acknowledgments", "acknowledgements", "references", "bibliography", "appendix",
    "supplementary material", "data availability", "ethics statement",
)
REFERENCE_TITLES = {"references", "bibliography", "literature cited"}
NUMBERED_RE = re.compile(r"^((\d+(\.\d+){0,3})\.?|[IVXLC]+\.|[A-Z]\.(\d+)?)\s+\S")
CAPTION_RE = re.compile(r"^(fig(ure)?\.?|table|tab\.)\s*\d+[a-z]?\s*[:.|]", re.I)
LIGATURES = {"ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl"}


@dataclass
class Section:
    title: str
    level: int
    text: str
    is_references: bool = False

    @property
    def n_chars(self) -> int:
        return len(self.text)


@dataclass
class Paper:
    title: str
    abstract: str
    sections: list[Section]
    captions: list[str] = field(default_factory=list)
    page_count: int = 0
    source: str = ""

    def body_sections(self, include_references: bool = False) -> list[Section]:
        return [s for s in self.sections if include_references or not s.is_references]

    def full_text(self, include_references: bool = False) -> str:
        parts = [f"TITLE: {self.title}"]
        if self.abstract:
            parts.append(f"ABSTRACT:\n{self.abstract}")
        for s in self.body_sections(include_references):
            parts.append(f"## {s.title}\n{s.text}")
        return "\n\n".join(parts)


@dataclass
class _Line:
    text: str
    size: float
    bold: bool
    page: int
    y0: float
    block_id: tuple[int, int]


def _clean(s: str) -> str:
    for k, v in LIGATURES.items():
        s = s.replace(k, v)
    s = unicodedata.normalize("NFKC", s)
    return re.sub(r"[ \t]+", " ", s).strip()


def _norm_for_repeat(s: str) -> str:
    return re.sub(r"\d+", "#", s.lower()).strip()


def _read_lines(doc: pymupdf.Document) -> list[_Line]:
    out: list[_Line] = []
    for pno, page in enumerate(doc):
        d = page.get_text("dict")
        for bno, block in enumerate(d.get("blocks", [])):
            if block.get("type") != 0:
                continue
            for line in block.get("lines", []):
                spans = [s for s in line.get("spans", []) if s.get("text", "").strip()]
                if not spans:
                    continue
                text = _clean("".join(s["text"] for s in line["spans"]))
                if not text:
                    continue
                chars = sum(len(s["text"]) for s in spans)
                size = sum(s["size"] * len(s["text"]) for s in spans) / max(chars, 1)
                bold_chars = sum(len(s["text"]) for s in spans if s.get("flags", 0) & 16
                                 or "bold" in s.get("font", "").lower())
                out.append(_Line(text, round(size, 1), bold_chars > 0.6 * chars, pno,
                                 line["bbox"][1], (pno, bno)))
    return out


def _drop_running_heads(lines: list[_Line], n_pages: int) -> list[_Line]:
    if n_pages < 3:
        return lines
    pages_with = Counter()
    seen = set()
    for ln in lines:
        key = (ln.page, _norm_for_repeat(ln.text))
        if key not in seen:
            seen.add(key)
            pages_with[_norm_for_repeat(ln.text)] += 1
    threshold = max(3, int(0.4 * n_pages))
    repeated = {k for k, c in pages_with.items() if c >= threshold and len(k) < 120}
    # Also drop bare page numbers
    return [ln for ln in lines
            if _norm_for_repeat(ln.text) not in repeated and not re.fullmatch(r"\d{1,4}", ln.text)]


def _heading_level(text: str) -> int:
    m = re.match(r"^(\d+(\.\d+)*)", text)
    return m.group(1).count(".") + 1 if m else 1


def _is_heading(ln: _Line, body_size: float) -> bool:
    t = ln.text
    if len(t) > 100 or len(t) < 3 or t.endswith((",", ";")) or CAPTION_RE.match(t):
        return False
    words = t.split()
    if len(words) > 12:
        return False
    bare = re.sub(r"^((\d+(\.\d+)*)\.?|[IVXLC]+\.|[A-Z]\.)\s*", "", t).strip(" .:").lower()
    known = bare in KNOWN_SECTIONS
    numbered = bool(NUMBERED_RE.match(t)) and not re.match(r"^\d+(\.\d+)?\s*(%|x|ms|s)\b", t)
    bigger = ln.size >= body_size * 1.12
    if known and (ln.bold or bigger or numbered or t.isupper()):
        return True
    if numbered and (ln.bold or bigger) and t[0:1].isdigit() and not t.rstrip().endswith("."):
        return True
    if bigger and ln.bold and words[0][0:1].isupper():
        return True
    return False


def extract_paper(path: str | Path, reporter=None) -> Paper:
    """Extract a structured Paper from a PDF.

    ``reporter`` is an optional :class:`paper2pod.progress.ProgressReporter`;
    the CLI passes none and behaves exactly as before.
    """
    if reporter is not None:
        reporter.set_stage("extract", "Extracting text from PDF")
    path = Path(path)
    doc = pymupdf.open(path)
    lines = _drop_running_heads(_read_lines(doc), doc.page_count)
    if not lines:
        raise ValueError(f"No extractable text in {path} (scanned PDF? run OCR first, e.g. ocrmypdf)")

    size_weights = Counter()
    for ln in lines:
        size_weights[ln.size] += len(ln.text)
    body_size = size_weights.most_common(1)[0][0]

    # Title: largest text on page 1 (top half), excluding tiny fragments.
    p1 = [ln for ln in lines if ln.page == 0]
    meta_title = (doc.metadata or {}).get("title", "").strip()
    title = meta_title
    if p1:
        max_size = max(ln.size for ln in p1)
        title_lines = [ln.text for ln in p1 if ln.size == max_size and ln.size > body_size * 1.2]
        if title_lines and (not meta_title or len(meta_title) < 8):
            title = " ".join(title_lines[:4])
    title = title or path.stem

    sections: list[Section] = []
    captions: list[str] = []
    cur_title, cur_level, buf = "Front matter", 1, []
    prev_block = None
    caption_buf: list[str] | None = None

    def flush():
        text = "\n".join(buf).strip()
        text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)          # de-hyphenate
        text = re.sub(r"(?<![.\n:])\n(?!\n)", " ", text)       # join wrapped lines
        if text or not sections:
            bare = re.sub(r"^((\d+(\.\d+)*)\.?|[IVXLC]+\.)\s*", "", cur_title).strip(" .:").lower()
            sections.append(Section(cur_title, cur_level, text, bare in REFERENCE_TITLES))

    for ln in lines:
        if ln.block_id != prev_block:
            if caption_buf is not None:
                captions.append(" ".join(caption_buf))
                caption_buf = None
            if buf:
                buf.append("")  # paragraph break
            prev_block = ln.block_id
        if _is_heading(ln, body_size):
            if ln.page == 0 and ln.text in title:
                continue  # title line, not a section
            flush()
            cur_title, cur_level, buf = ln.text, _heading_level(ln.text), []
            continue
        if CAPTION_RE.match(ln.text):
            caption_buf = [ln.text]
        elif caption_buf is not None:
            caption_buf.append(ln.text)
        buf.append(ln.text)
    if caption_buf:
        captions.append(" ".join(caption_buf))
    flush()

    sections = [s for s in sections if s.text or s.title != "Front matter"]

    # Abstract: explicit section, else "Abstract" paragraph inside front matter.
    abstract = ""
    for s in list(sections):
        if s.title.strip(" .:").lower() == "abstract":
            abstract = s.text
            sections.remove(s)
            break
    if not abstract and sections and sections[0].title == "Front matter":
        m = re.search(r"\babstract\b[\s.:—-]*(.+)", sections[0].text, re.I | re.S)
        if m:
            abstract = m.group(1).strip()
            sections[0].text = sections[0].text[: m.start()].strip()

    # Fallback: no structure detected -> page-sized pseudo-sections.
    real = [s for s in sections if s.title != "Front matter"]
    if len(real) < 2:
        sections = []
        for pno, page in enumerate(doc):
            t = _clean(page.get_text())
            if t:
                sections.append(Section(f"Page {pno + 1}", 1, t))

    return Paper(title=title, abstract=abstract, sections=sections,
                 captions=captions, page_count=doc.page_count, source=str(path))
