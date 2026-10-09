"""Generate a synthetic multi-page 'paper' PDF with headings, running headers and captions."""
from __future__ import annotations

import random
import sys

import pymupdf

SENTS = [
    "We propose a sparse attention mechanism that scales linearly with sequence length.",
    "The model is trained for 300k steps with a batch size of 256 and a learning rate of 3e-4.",
    "On the benchmark it reaches 92.4% accuracy, compared with 88.1% for the strongest baseline.",
    "This suggests that locality priors remain useful even at large scale.",
    "We ablate the routing component and observe a drop of 2.3 points.",
    "The computational cost is reduced by a factor of 4.1 at sequence length 16k.",
    "Prior work (Smith et al., 2020) relied on fixed patterns that ignore content.",
    "Our analysis shows that the learned clusters align with syntactic structure.",
]
SECTIONS = ["1 Introduction", "2 Related Work", "3 Method", "4 Experiments", "5 Results",
            "6 Limitations", "7 Conclusion", "References"]


def build(path: str, paras_per_section: int = 6, seed: int = 0) -> None:
    rng = random.Random(seed)
    doc = pymupdf.open()
    page, y = None, 0.0

    def new_page():
        nonlocal page, y
        page = doc.new_page()
        page.insert_text((72, 40), "Preprint. Under review.", fontsize=8)
        page.insert_text((300, 800), str(doc.page_count), fontsize=8)
        y = 72

    def write(text, size=10, bold=False, gap=4):
        nonlocal y
        font = "hebo" if bold else "helv"
        width = 470
        lines, cur = [], ""
        for w in text.split():
            if pymupdf.get_text_length(cur + " " + w, fontname=font, fontsize=size) > width:
                lines.append(cur)
                cur = w
            else:
                cur = (cur + " " + w).strip()
        lines.append(cur)
        if y + len(lines) * size * 1.3 > 770:
            new_page()
        for ln in lines:
            page.insert_text((72, y), ln, fontsize=size, fontname=font)
            y += size * 1.3
        y += gap

    new_page()
    write("Sparse Routing Attention for Long Sequences", size=18, bold=True, gap=10)
    write("Ada Lovelace, Alan Turing", size=10)
    write("Abstract", size=12, bold=True)
    write(" ".join(rng.sample(SENTS, 4)))
    for s in SECTIONS:
        write(s, size=12, bold=True, gap=6)
        if s == "References":
            for i in range(10):
                write(f"[{i + 1}] A. Author. A paper title {i}. In Proceedings, 2019.", size=9, gap=1)
            continue
        for p in range(paras_per_section):
            write(" ".join(rng.choice(SENTS) for _ in range(rng.randint(4, 8))))
            if s == "5 Results" and p == 1:
                write("Table 1: Accuracy on the benchmark. Our method outperforms all baselines.", size=9)
            if s == "3 Method" and p == 0:
                write("Figure 2: Overview of the routing mechanism.", size=9)
    doc.save(path)


if __name__ == "__main__":
    build(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 6)
