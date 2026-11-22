"""Writes a small demo library for looking at the Linux UI (screenshot.sh).
Only finished papers: anything mid-conversion would resume and call the LLM."""
import json
import os
import sys

from pdf_fixture import one_page_pdf


def pdf(lines):
    """A minimal one-page PDF with `lines` of text."""
    ops = ["BT /F1 22 Tf 60 720 Td 28 TL"] + [f"({l}) Tj T*" for l in lines] + ["ET"]
    stream = "\n".join(ops).encode()
    return one_page_pdf(stream, font="Helvetica-Bold")


PAPERS = [
    ("attention", "Attention Is All You Need", ["Ashish Vaswani", "Noam Shazeer"], ["nlp"], True, "done"),
    ("resnet", "Deep Residual Learning for Image Recognition", ["Kaiming He", "Xiangyu Zhang"], ["vision"], False, "done"),
    ("gpt3", "Language Models are Few-Shot Learners", ["Tom Brown", "Ashish Vaswani"], ["nlp"], False, "done"),
    ("broken", "A Paper That Failed to Convert", ["Ada Lovelace"], [], False, "error"),
]

root = os.path.join(sys.argv[1], "papers")
for day, (pid, title, authors, tags, fav, state) in enumerate(PAPERS, 1):
    folder = os.path.join(root, pid)
    os.makedirs(folder, exist_ok=True)
    words = title.split()
    open(os.path.join(folder, "source.pdf"), "wb").write(pdf([" ".join(words[:3]), " ".join(words[3:])] + authors))
    record = {
        "id": pid, "title": title, "filename": pid + ".pdf", "has_pdf": True,
        "has_script": state == "done", "has_audio": False, "created_iso": f"2026-10-{day:02d}T09:00:00Z",
        "state": state, "tags": tags, "favorite": fav, "authors": authors, "affiliations": [],
        "doi": "", "read": False, "depth": "summary", "progress": 0, "duration": 0,
        "stage": "done" if state == "done" else "script",
        "message": "Done" if state == "done" else None,
        "status_error": None if state == "done" else "The LLM didn't answer (timeout).",
    }
    json.dump(record, open(os.path.join(folder, "paper.json"), "w"))
print(f"Demo library with {len(PAPERS)} papers in {root}")
