"""Client-side synthesis worker, run inside the desktop app's own venv.

The Electron app spawns this with the paper's api base + token. It pulls
``script.json`` from the server, synthesizes the podcast locally (kokoro), then
uploads the finished mp3/wav/srt back to the server, which finalizes the paper.

It never uses the server's venv — the desktop app builds a dedicated one.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import urllib.request
from pathlib import Path


def auth_get(base: str, token: str, path: str) -> bytes:
    url = base.rstrip("/") + path
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def post(base: str, token: str, path: str, *, json_body: dict | None = None,
         fields: dict[str, bytes] | None = None) -> None:
    url = base.rstrip("/") + path
    boundary = "----paper2pod" + "A" * 16
    if json_body is not None:
        body = json.dumps(json_body).encode()
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
    else:
        parts = []
        for name, data in (fields or {}).items():
            fname = {"wav": "podcast.wav", "srt": "podcast.srt", "mp3": "podcast.mp3"}[name]
            parts.append(
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; "
                f"filename=\"{fname}\"\r\nContent-Type: application/octet-stream\r\n\r\n".encode()
                + data + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=600) as resp:
        resp.read()


def report(base: str, token: str, paper_id: str, progress: float, message: str) -> None:
    post(base, token, f"/api/papers/{paper_id}/audio-progress",
         json_body={"progress": progress, "message": message})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--api", required=True)
    ap.add_argument("--token", default="")
    ap.add_argument("--paper", required=True)
    ap.add_argument("--device", default="auto")
    ap.add_argument("--backend", default="kokoro")
    ap.add_argument("--cache", default="~/.cache/paper2pod")
    ap.add_argument("--chunk-upload", action="store_true",
                    help="upload each finished turn instead of the full render")
    args = ap.parse_args()

    # The caller passes the API base (path helpers below prefix /api/ themselves),
    # so strip a trailing /api if present to avoid /api/api/ duplication.
    base = args.api.rstrip("/")
    if base.endswith("/api"):
        base = base[: -len("/api")]

    from paper2pod.audio import render
    from paper2pod.config import TTSConfig
    from paper2pod.script import Script
    from paper2pod.tts import create_backend

    cache_dir = Path(args.cache).expanduser()

    report(base, args.token, args.paper, 0.0, "Fetching script…")
    script_bytes = auth_get(base, args.token, f"/api/papers/{args.paper}/transcript")

    with tempfile.TemporaryDirectory(prefix="p2p-synth-") as td:
        script_path = Path(td) / "script.json"
        script_path.write_bytes(script_bytes)
        script = Script.load(script_path)
        out_stem = Path(td) / "podcast"
        cfg = TTSConfig(backend=args.backend, device=args.device, output_format="mp3")
        try:
            backend = create_backend(args.backend, args.device, **cfg.options)
        except Exception as e:  # noqa: BLE001
            report(base, args.token, args.paper, 0.0, f"Synthesis error: {e}")
            print(f"ERROR {e}", flush=True)
            return 2
        report(base, args.token, args.paper, 0.02, "Synthesizing audio…")

        from paper2pod.progress import ProgressReporter, BANDS

        def on_progress(msg: str) -> None:
            print(msg, flush=True)

        # ProgressReporter reports overall progress in the server's "audio" band
        # (0.70..0.95). The /audio-progress endpoint remaps a 0..1 fraction back to
        # 0.72..0.95, so normalize to that fraction before sending.
        a_start, a_end = BANDS.get("audio", (0.70, 0.95))

        def on_reporter_change(r: ProgressReporter) -> None:
            frac = (r.progress - a_start) / (a_end - a_start) if a_end > a_start else 0.0
            report(base, args.token, args.paper, max(0.0, min(1.0, frac)), r.message)

        reporter = ProgressReporter(stage="audio", progress=0.02)
        reporter.on_change(lambda: on_reporter_change(reporter))
        reporter.set_message("Synthesizing turn 0")

        res = render(script, backend, cfg, out_stem, cache_dir,
                     progress=on_progress, reporter=reporter)
        report(base, args.token, args.paper, 0.85, "Uploading audio…")
        fields = {}
        for p, name in ((res.wav, "wav"), (res.srt, "srt"), (res.mp3, "mp3")):
            if p and Path(p).is_file():
                fields[name] = Path(p).read_bytes()
        post(base, args.token, f"/api/papers/{args.paper}/audio", fields=fields)
    report(base, args.token, args.paper, 1.0, "Done")
    print(f"DONE {res.duration_s:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())