"""Writes a small demo library for looking at the Linux UI (screenshot.sh), with a short baked
episode (tones) for each finished paper so the player can be tried.
Only finished papers: anything mid-conversion would resume and call the LLM."""
import json
import os
import sys


def pdf(lines):
    """A minimal one-page PDF with `lines` of text."""
    ops = ["BT /F1 22 Tf 60 720 Td 28 TL"] + [f"({l}) Tj T*" for l in lines] + ["ET"]
    stream = "\n".join(ops).encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


PAPERS = [
    ("attention", "Attention Is All You Need", ["Ashish Vaswani", "Noam Shazeer"], ["nlp"], True, "done"),
    ("resnet", "Deep Residual Learning for Image Recognition", ["Kaiming He", "Xiangyu Zhang"], ["vision"], False, "done"),
    ("gpt3", "Language Models are Few-Shot Learners", ["Tom Brown", "Ashish Vaswani"], ["nlp"], False, "done"),
    ("broken", "A Paper That Failed to Convert", ["Ada Lovelace"], [], False, "error"),
]

def tone_wav(freq, seconds, rate=24000):
    """A quiet sine tone as 24 kHz mono 16-bit WAV with a 44-byte header (the stored turn layout)."""
    import math
    import struct
    n = int(rate * seconds)
    pcm = b"".join(struct.pack("<h", int(3000 * math.sin(2 * math.pi * freq * i / rate))) for i in range(n))
    header = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return header + b"data" + struct.pack("<I", len(pcm)) + pcm


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
    if state == "done":
        # A short baked episode (soft tones as stand-in voices), so the player has something to play.
        turns = [("Jordan", f"Today we talk about {title}."), ("Ada", "Thanks for having me."),
                 ("Jordan", "Let's start with the main idea.")]
        transcript = {"paper_title": title, "speakers": [{"name": "Jordan"}, {"name": "Ada"}],
                      "segments": [{"title": "Introduction", "turns": [{"speaker": s, "text": t} for s, t in turns]}]}
        json.dump(transcript, open(os.path.join(folder, "transcript.json"), "w"))
        os.makedirs(os.path.join(folder, "turns"), exist_ok=True)
        durations = []
        for i, _ in enumerate(turns):
            open(os.path.join(folder, "turns", f"{i}.wav"), "wb").write(tone_wav(330 + 110 * i, 4.0))
            durations.append(4.0)
        json.dump({"durations": durations}, open(os.path.join(folder, "audio.json"), "w"))
        record["has_audio"] = True
        record["duration"] = sum(durations)
    json.dump(record, open(os.path.join(folder, "paper.json"), "w"))
print(f"Demo library with {len(PAPERS)} papers in {root}")
