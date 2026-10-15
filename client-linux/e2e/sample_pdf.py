"""Writes a small multi-line 'paper' PDF for the end-to-end import."""
import sys

LINES = [
    "Attention Mechanisms in Modern Models",
    "Ada Lovelace, Grace Hopper",
    "Abstract",
    "We study attention, which lets a model weigh every word of its input when producing each output.",
    "1 Introduction",
    "Recurrent networks read text one word at a time and forget distant context.",
    "2 Method",
    "Queries, keys and values are projected from the input and combined with a softmax over similarities.",
    "3 Results",
    "On translation benchmarks attention outperforms a recurrent baseline by a clear margin.",
]


def build(lines):
    ops = ["BT /F1 12 Tf 72 740 Td 16 TL"] + [f"({l}) Tj T*" for l in lines] + ["ET"]
    stream = "\n".join(ops).encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
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


open(sys.argv[1], "wb").write(build(LINES))
