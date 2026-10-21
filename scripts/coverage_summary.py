#!/usr/bin/env python3
"""Turn `llvm-cov export -summary-only` JSON into a Markdown coverage table
(shown on the GitHub Actions run summary) and totals.

    coverage_summary.py summary.json OUT_DIR

Writes OUT_DIR/summary.md and OUT_DIR/totals.json, and prints the totals.
Two numbers are reported: every source file, and "logic" (models,
controllers, helpers), which leaves out the SwiftUI views that have no UI
tests and would otherwise hide what the suite actually protects.
"""
import json
import sys
from pathlib import Path

# SwiftUI view code: excluded from the "logic" number.
UI_PREFIXES = ("macOS/Views/", "macOS/Components/", "macOS/App/", "macOS/Support/Theme.swift")


def relative(path: str) -> str:
    """A source path relative to Sources/Papertalk/."""
    marker = "/Sources/Papertalk/"
    return path.split(marker, 1)[1] if marker in path else path


def pct(covered: int, count: int) -> float:
    """Percentage covered; 100 when there's nothing to cover."""
    return 100.0 * covered / count if count else 100.0


def main() -> None:
    """Write summary.md and totals.json from the llvm-cov summary JSON."""
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    data = json.loads(src.read_text())["data"][0]

    rows = []
    for f in data["files"]:
        name = relative(f["filename"])
        lines = f["summary"]["lines"]
        rows.append((name, lines["covered"], lines["count"]))
    rows.sort()

    total_cov = sum(r[1] for r in rows)
    total_cnt = sum(r[2] for r in rows)
    logic = [r for r in rows if not r[0].startswith(UI_PREFIXES)]
    logic_cov = sum(r[1] for r in logic)
    logic_cnt = sum(r[2] for r in logic)
    totals = {
        "lines_total": round(pct(total_cov, total_cnt), 2),
        "lines_logic": round(pct(logic_cov, logic_cnt), 2),
        "covered_total": total_cov, "count_total": total_cnt,
        "covered_logic": logic_cov, "count_logic": logic_cnt,
    }

    md = [
        "## Test coverage",
        "",
        f"**Logic (models, controllers, helpers): {totals['lines_logic']:.1f}%** of lines "
        f"({logic_cov}/{logic_cnt}) · All code including SwiftUI views: "
        f"{totals['lines_total']:.1f}% ({total_cov}/{total_cnt})",
        "",
        "<details><summary>Per file (lines)</summary>",
        "",
        "| File | Covered | Lines | % |",
        "|---|---:|---:|---:|",
    ]
    for name, cov, cnt in rows:
        tag = " _(UI)_" if name.startswith(UI_PREFIXES) else ""
        md.append(f"| `{name}`{tag} | {cov} | {cnt} | {pct(cov, cnt):.1f}% |")
    md += ["", "</details>", ""]

    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.md").write_text("\n".join(md))
    (out / "totals.json").write_text(json.dumps(totals, indent=2) + "\n")
    print(f"Coverage: logic {totals['lines_logic']:.1f}% · all code {totals['lines_total']:.1f}%")


if __name__ == "__main__":
    main()
