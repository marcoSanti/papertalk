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
DOI_RE = re.compile(r"\b10\.\d{4,9}/[-._;()/:A-Za-z0-9]+\b")
_AUTHOR_SEP = re.compile(r"[;,]\s*|\s+and\s+", re.I)


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
    authors: list[str] = field(default_factory=list)
    affiliations: list[str] = field(default_factory=list)
    doi: str = ""
    
    def header(self) -> str:
        parts = [f"TITLE: {self.title}"]
        if self.authors:
            parts.append("AUTHORS: " + ", ".join(self.authors))
        if self.doi:
            parts.append(f"DOI: {self.doi}")
        return "\n".join(parts)

    def body_sections(self, include_references: bool = False) -> list[Section]:
        return [s for s in self.sections if include_references or not s.is_references]

    def full_text(self, include_references: bool = False) -> str:
        parts = [self.header()]
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


_AFFIL_SIGNAL = re.compile(
    r"\b(?:university|univ\.?|college|school|institute|institut|department|dept\.?|"
    r"laborator|research center|research group|research|centre|center|academy|medicine|"
    r"hospital|faculty|physics|computer science|biology|chemistry|engineering|"
    r"mathematics|google|microsoft|amazon|facebook|meta\b|apple|ibm|technolog)\b",
    re.I)


def _looks_like_title(text: str) -> bool:
    """True for a line that could be a paper title (excludes stamps/mastheads)."""
    t = text.strip()
    if len(t) < 3 or len(t) > 220:
        return False
    low = t.lower()
    # arXiv submission stamps / DOIs / bare page numbers / lone journal years.
    if re.search(r"\barxiv:|\[\s*cs\.[a-z]+\s*\]", low):
        return False
    if re.search(r"^10\.\d{4,}/\S+", low):
        return False
    if re.fullmatch(r"[\d.,\s-]+", t):
        return False
    # "Future Generation Computer Systems" style journal-only header is caught by
    # _drop_running_heads; here just reject lines that are short + only a year/vol.
    if re.fullmatch(r"[A-Za-z&.,' -]*\d{4}", t) and len(t) < 40:
        return False
    return True


def _plausible_title(t: str, stem: str) -> bool:
    """Trust a metadata/other title only if it actually looks like a paper title."""
    t = t.strip()
    return (8 <= len(t) <= 250 and "arxiv:" not in t.lower()
            and t not in (stem, stem.strip()) and t != "Untitled")


_AFFIL_SEP = re.compile(r"[;,]")

_AFFIL_STOP = re.compile(
    r"\b(?:university|univ\.?|department|dept\.?|institute|institut|faculty|school|"
    r"college|laboratory|lab\b|research|centre|center|academy|medicine|hospital)\b",
    re.I)


def _authors_from_page(p1: list[_Line], title_end_y: float) -> list[str]:
    """Author names: the capitalized block directly beneath the title.

    Scans from the title's bottom edge down page 1, collecting contiguous lines
    that read as names (mostly Title Case, footnote keys allowed), stopping at
    the first affiliation/prose line. Each split-off name has its trailing
    footnote key (``, a``, ``1``) removed.
    """
    block: list[str] = []
    started = False
    for ln in p1:
        if ln.y0 <= title_end_y:
            continue
        t = ln.text.strip()
        if not t:
            continue
        if _stops_author_block(t):
            if started:
                break
            continue
        if not _is_author_line(t):
            if started:
                break
            continue
        started = True
        block.append(t)
    names: list[str] = []
    for part in _AUTHOR_SEP.split(" ".join(block)):
        part = re.sub(r"[*†‡#\u0301\u030a]", "", part).strip()
        part = re.sub(r"\s+[a-z0-9]\s*$", "", part).strip()   # "Name, a" -> "Name"
        part = re.sub(r"\d+$", "", part).strip()               # "Name1" -> "Name"
        part = part.strip(" .,;:")
        if _plausible_author_name(part):
            names.append(part)
    return names


def _is_author_line(t: str) -> bool:
    s = re.sub(r"[*†‡#]", "", t).strip()
    if not s or len(s) > 180 or "@" in s or "[" in s or "(" in s or ")" in s or "/" in s:
        return False
    low = s.lower()
    if re.search(r"\b(university|department|dept|institut|faculty|school|college|"
                 r"research|center|centre|laboratory|journal|homepage|elsevier|"
                 r"sciencedirect|highlights|abstract|article info|keywords)\b", low):
        return False
    words = [w for w in s.split() if re.search(r"[A-Za-z]", w)]
    if len(words) < 2:
        return False
    capped = sum(1 for w in words if w[0].isupper())
    return capped >= max(2, int(0.5 * len(words)))


def _stops_author_block(t: str) -> bool:
    """A line that clearly ends the author block (affiliation / section head)."""
    low = t.lower()
    return bool(re.search(r"\b(contributing authors|corresponding author|email|address|"
                          r"universidade|\d{4}"
                          r"|university|department|dept|institut|faculty|college|"
                          r"research center|abstract|highlights|article info)\b", low))


def _plausible_author_name(n: str) -> bool:
    n = n.strip(" .,;:")
    if len(n) < 3 or len(n) > 60 or not re.search(r"[A-Za-z]", n):
        return False
    if n.isupper() and len(n) < 4:
        return False
    return bool(re.search(r"\b[A-Z]", n))


def _affiliations(p1: list[_Line], title: str, authors: list[str]) -> list[str]:
    """Best-effort affiliations: institution-looking lines on page. 1.

    Up to 6 distinct institution lines, dropping emails, reference brackets and
    prose that merely *mentions* an org (e.g. "…using IBM's…"). A footnote-style
    leading key (``a``, ``1``) is stripped. Correctly tying each author to their
    key needs a layout parse; this is display-only.
    """
    # ponytail: crude heuristic; structured footnotes with 1-letter superscript
    # keys are frequent — correctly tying author->affiliation needs a layout parse
    # (see pdfplumber tables) that isn't worth it for display-only metadata.
    known = {n.lower() for n in authors} | {title.lower()}
    out: list[str] = []
    seen: set[str] = set()
    for ln in p1:
        t = ln.text.strip()
        if (len(t) < 6 or len(t) > 140 or "@" in t or "[" in t or t.lower() in known
                or len(re.findall(r"[A-Za-z]", t)) < 4):
            continue
        # strip a leading footnote key ("a " / "1 ") only if it precedes a Capital.
        m = re.match(r"^([0-9]|[a-z])(?=\s+[A-Z])", t)
        if m:
            t = t[m.end():].strip()
        head = t.split()[0] if t.split() else ""
        if not head or (head[0].islower() and not head[0].isdigit()):
            continue  # lowercase prose line, not an institution
        if _AFFIL_SIGNAL.search(t):
            low = t.lower()
            m = _AFFIL_STOP.search(low)
            if m and low.index(m.group(0)) > 60:
                continue  # org mentioned deep in a sentence -> prose
            t = re.sub(r"^[a-z0-9*#]+\s+", "", t, count=1)  # leading footnote key
            k = t.lower()
            if k not in seen:
                seen.add(k)
                out.append(t)
        if len(out) >= 6:
            break
    return out


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
    if n_pages < 2:
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

    # Title: largest text in the top half of page 1, taken as a contiguous run of
    # same-size lines. A real title is usually a multi-line block; an isolated
    # large line sitting above it is a journal masthead ("J. Parallel Distrib.
    # Comput." style) that running-head removal missed because it only appears on
    # page 1. So prefer the first multi-line cluster, else the topmost large line.
    p1 = [ln for ln in lines if ln.page == 0]
    page_h = doc[0].rect.height if doc else 0
    top = [ln for ln in p1 if ln.y0 < page_h * 0.55 and _looks_like_title(ln.text)]
    meta_title = (doc.metadata or {}).get("title", "").strip()
    title = meta_title
    title_end_y = -1.0
    if not (isinstance(title, str) and _plausible_title(title, path.stem)) and top:
        target = max(ln.size for ln in top)
        kept = [ln for ln in top if ln.size >= target * 0.95]
        clusters: list[list[_Line]] = []
        for ln in kept:
            if clusters and clusters[-1][-1].y0 + 40 > ln.y0:
                clusters[-1].append(ln)
            else:
                clusters.append([ln])
        run = next((c for c in clusters if len(c) >= 2), clusters[0])
        title = " ".join(ln.text for ln in run).strip()
        title_end_y = run[-1].y0
    title = title or path.stem

    # Authors: PDF metadata first, else the name block directly under the title.
    authors: list[str] = []
    meta = doc.metadata or {}
    raw_authors = (meta.get("author") or "").strip()
    if raw_authors:
        authors = [_clean(p) for p in _AUTHOR_SEP.split(raw_authors) if p.strip()]
    if not authors and p1:
        authors = _authors_from_page(p1, title_end_y)

    # DOI: metadata first, else the first one anywhere on page 1.
    doi = (meta.get("doi") or "").strip()
    p1_text = _clean(" ".join(ln.text for ln in p1)) if p1 else ""
    if not doi and p1_text and DOI_RE.search(p1_text):
        doi = DOI_RE.search(p1_text).group(0)

    affiliations = _affiliations(p1, title, authors)

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
                 captions=captions, page_count=doc.page_count, source=str(path),
                 authors=authors, affiliations=affiliations, doi=doi)
