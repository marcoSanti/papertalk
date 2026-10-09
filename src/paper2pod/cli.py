"""Command line interface.

  paper2pod run paper.pdf                 # PDF -> script -> audio (resumable)
  paper2pod script paper.pdf              # stop after the script (edit it, then synth)
  paper2pod synth out/paper/script.json   # script -> audio only
  paper2pod extract paper.pdf             # inspect PDF structure detection
  paper2pod models [--probe]              # list remote models, discover context window
  paper2pod backends                      # list TTS plugins, devices
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from dataclasses import asdict
from pathlib import Path

from .config import Config, load_config


def _progress(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _apply_overrides(cfg: Config, a: argparse.Namespace) -> Config:
    for attr, target, field in [("model", cfg.llm, "model"), ("base_url", cfg.llm, "base_url"),
                                ("context_window", cfg.llm, "context_window"),
                                ("style", cfg.script, "style"), ("minutes", cfg.script, "target_minutes"),
                                ("language", cfg.script, "language"), ("backend", cfg.tts, "backend"),
                                ("device", cfg.tts, "device"), ("format", cfg.tts, "output_format")]:
        v = getattr(a, attr, None)
        if v is not None:
            setattr(target, field, v)
    if getattr(a, "probe", False):
        cfg.llm.probe_context = "always"
    return cfg


def _workdir(cfg: Config, pdf: Path, out: str | None, fresh: bool) -> Path:
    from .pipeline import write_run_fingerprint
    wd = Path(out or "out") / pdf.stem
    wd.mkdir(parents=True, exist_ok=True)
    write_run_fingerprint(wd, cfg, fresh)
    return wd


def cmd_extract(cfg: Config, a) -> None:
    from .pdf_extract import extract_paper
    p = extract_paper(a.pdf)
    print(f"Title: {p.title}\nPages: {p.page_count}\nAbstract: {len(p.abstract)} chars\n")
    for i, s in enumerate(p.sections):
        flag = "  [refs]" if s.is_references else ""
        print(f"{i:3d}. {s.title[:70]:70s} {s.n_chars:7d} chars{flag}")
    print(f"\n{len(p.captions)} figure/table captions")
    if a.json:
        Path(a.json).write_text(json.dumps(asdict(p), indent=2, ensure_ascii=False))


def cmd_script(cfg: Config, a) -> None:
    from .pipeline import run_script
    wd = _workdir(cfg, Path(a.pdf), a.out, a.fresh)
    run_script(str(a.pdf), cfg, wd)


def cmd_run(cfg: Config, a) -> None:
    from .pipeline import run_paper
    wd = _workdir(cfg, Path(a.pdf), a.out, a.fresh)
    run_paper(str(a.pdf), cfg, wd)


def cmd_synth(cfg: Config, a) -> None:
    from .pipeline import run_paper
    from .script import Script
    path = Path(a.script)
    script = Script.load(path)
    if a.voices:  # e.g. --voices af_heart,am_michael
        for spk, v in zip(script.speakers, a.voices.split(",")):
            spk["voice"] = v
    media = _synth_audio(cfg, script, path.parent)


def _synth_audio(cfg: Config, script, wd: Path) -> None:
    """Script -> audio only (kept thin for `synth`; full runs use pipeline.run_paper)."""
    from .audio import render
    from .tts import create_backend

    wd = Path(wd)
    _progress(f"Loading TTS backend '{cfg.tts.backend}' (device={cfg.tts.device})...")
    with create_backend(cfg.tts.backend, cfg.tts.device, **cfg.tts.options) as backend:
        _progress(f"  using device: {backend.device}")
        res = render(script, backend, cfg.tts, wd / "podcast", Path(cfg.cache_dir).expanduser(),
                     progress=_progress)
    rtf = res.synth_s / res.duration_s if res.duration_s else 0
    _progress(f"Audio: {res.duration_s / 60:.1f} min (synthesis {res.synth_s:.0f}s, RTF {rtf:.2f})")
    for p in (res.mp3, res.wav, res.srt):
        if p:
            _progress(f"  -> {p}")


def cmd_serve(cfg: Config, a) -> None:
    import uvicorn

    from . import webapp
    # Point workers at the effective (CLI-overridden) config and TTS/LLM flags.
    overrides = {}
    for attr, key in [("backend", "tts.backend"), ("device", "tts.device"),
                      ("format", "tts.output_format"), ("model", "llm.model"),
                      ("style", "script.style"), ("minutes", "script.target_minutes"),
                      ("language", "script.language")]:
        v = getattr(a, attr, None)
        if v is not None:
            overrides[key] = v
    webapp.set_serving_options(a.config, overrides)
    _progress(f"Serving web UI on http://{a.host}:{a.port}  (library: {webapp.LIBRARY})")
    uvicorn.run(webapp.app, host=a.host, port=a.port)


def cmd_models(cfg: Config, a) -> None:
    from .llm import LLMClient
    cfg.llm.model = cfg.llm.model or "-"
    llm = LLMClient(cfg.llm, cfg.cache_dir)
    for m in llm.list_models():
        mark = "*" if m.get("id") == cfg.llm.model else " "
        print(f"{mark} {m.get('id')}  ({m.get('owned_by', '?')})")
    if cfg.llm.model != "-":
        info = llm.discover_context(refresh=a.refresh or a.probe)
        b = llm.budget()
        print(f"\nModel {cfg.llm.model}: context window {info.window} tokens "
              f"(source: {info.source}, reliable: {info.reliable})")
        for n in info.notes:
            print(f"  - {n}")
        print(f"  budget per call: input {b.max_input}, output {b.max_output}; "
              f"~{llm.tokens.cpt:.2f} chars/token")


def cmd_backends(cfg: Config, a) -> None:
    from .tts.device import available_devices
    from .tts.registry import available_backends
    print("Devices available:", ", ".join(available_devices()))
    for name, path in available_backends().items():
        print(f"  {name:12s} {path}")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="paper2pod", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", help="YAML config file")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def llm_opts(p):
        p.add_argument("--model")
        p.add_argument("--base-url", dest="base_url")
        p.add_argument("--context-window", dest="context_window", type=int,
                       help="skip discovery and use this many tokens")
        p.add_argument("--probe", action="store_true", help="force the context-window probe")

    def script_opts(p):
        p.add_argument("pdf")
        p.add_argument("-o", "--out", help="output root (default ./out)")
        p.add_argument("--style", help="host_expert | peers | <custom>")
        p.add_argument("--minutes", type=float, help="target episode length")
        p.add_argument("--language")
        p.add_argument("--fresh", action="store_true", help="ignore cached notes/outline")

    def tts_opts(p):
        p.add_argument("--backend", help="kokoro | openai_http | null | module:Class")
        p.add_argument("--device", help="auto | cuda | mps | cpu")
        p.add_argument("--format", choices=["mp3", "wav"])

    p = sub.add_parser("run", help="PDF -> script -> audio")
    script_opts(p); llm_opts(p); tts_opts(p)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("script", help="PDF -> script only")
    script_opts(p); llm_opts(p)
    p.set_defaults(fn=cmd_script)

    p = sub.add_parser("synth", help="script.json -> audio")
    p.add_argument("script")
    p.add_argument("--voices", help="comma-separated voices for speaker 1,2")
    tts_opts(p)
    p.set_defaults(fn=cmd_synth)

    p = sub.add_parser("extract", help="show detected PDF structure")
    p.add_argument("pdf")
    p.add_argument("--json", help="also write the extraction to this file")
    p.set_defaults(fn=cmd_extract)

    p = sub.add_parser("models", help="list models; discover context window of --model")
    llm_opts(p)
    p.add_argument("--refresh", action="store_true", help="ignore cached context discovery")
    p.set_defaults(fn=cmd_models)

    p = sub.add_parser("backends", help="list TTS backends and devices")
    p.set_defaults(fn=cmd_backends)

    p = sub.add_parser("serve", help="run the FastAPI web UI server")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8170)
    llm_opts(p)
    tts_opts(p)
    p.add_argument("--tts", dest="backend", help="alias for --backend (TTS backend)")
    p.add_argument("--style", dest="style")
    p.add_argument("--minutes", dest="minutes", type=float)
    p.add_argument("--language", dest="language")
    p.set_defaults(fn=cmd_serve)

    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    for noisy in ("httpx", "openai", "httpcore"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    cfg = _apply_overrides(load_config(a.config), a)
    a.fn(cfg, a)


if __name__ == "__main__":
    main()
