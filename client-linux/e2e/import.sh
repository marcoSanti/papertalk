#!/usr/bin/env bash
# End-to-end import on Linux (AGENTS.md, "Linux port"): a sample PDF goes
# through the real pipeline (pypdfium2 → LLM → Kokoro → WAV) with a fake LLM,
# into a throwaway library. Run inside the dev container: client-linux/dev.sh client-linux/e2e/import.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'kill $LLM 2>/dev/null || true; rm -rf "$WORK"' EXIT

(cd "$ROOT/client-macos" && swift build --scratch-path .build-linux/main 2>&1 | grep -E "error|Build complete")
python3 "$ROOT/client-linux/e2e/sample_pdf.py" "$WORK/paper.pdf"
python3 "$ROOT/client-linux/e2e/fake_llm.py" 8765 & LLM=$!
sleep 1

# A throwaway HOME keeps the run away from real settings; the Kokoro model cache is shared.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export LLM_BASE_URL=http://127.0.0.1:8765/v1 PAPERTALK_MODEL=fake-model HOME="$WORK/home"
mkdir -p "$HOME"
"$ROOT/client-macos/.build-linux/main/debug/Papertalk" --import "$WORK/paper.pdf" --library "$WORK/library"

PAPER="$(ls -d "$WORK"/library/papers/*/ | head -1)"
echo "Library folder: $(ls "$PAPER" | tr '\n' ' ')"
echo "Turns: $(ls "$PAPER/turns" | wc -l) WAV files"
test -f "$PAPER/transcript.json" && test -f "$PAPER/audio.json"
python3 - "$PAPER" <<'PY'
import json, sys, soundfile as sf, glob
d = sys.argv[1]
t = json.load(open(d + "/transcript.json"))
print("Speakers:", [s["name"] for s in t["speakers"]], "| segments:", len(t["segments"]))
for w in sorted(glob.glob(d + "/turns/*.wav"))[:2]:
    info = sf.info(w)
    print(w.split("/")[-1], f"{info.samplerate} Hz, {info.channels} ch, {info.duration:.1f} s")
PY
echo "End-to-end import OK"
