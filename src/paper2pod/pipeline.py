"""Reusable pipeline orchestration, shared by the CLI and the web server.

``run_paper`` drives PDF -> script -> audio and writes the same artifacts the
CLI always produced (paper.json, script.json, script.md, notes.json,
outline.json, run.json, podcast.wav/srt/mp3). It takes an *optional*
:class:`paper2pod.progress.ProgressReporter` for the web server; the CLI passes
none and keeps its existing behaviour exactly.
"""
from __future__ import annotations

import json
import sys
import threading
from dataclasses import asdict
from pathlib import Path

from .config import Config
from .progress import ProgressReporter


def _progress(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class PipelineCancelled(RuntimeError):
    """Raised between stages when a job was asked to stop."""


def run_fingerprint(cfg: Config) -> dict:
    return {"model": cfg.llm.model, "style": cfg.script.style, "minutes": cfg.script.target_minutes,
            "language": cfg.script.language, "speakers": [asdict(s) for s in cfg.script.speakers[cfg.script.style]],
            "refs": cfg.script.include_references}


def write_run_fingerprint(workdir: str | Path, cfg: Config, fresh: bool = False) -> None:
    """Write run.json, invalidating cached notes/outline when settings changed.

    Mirrors the logic that used to live in CLI ``_workdir`` so both entry points
    share it.
    """
    wd = Path(workdir)
    fp = run_fingerprint(cfg)
    fp_path = wd / "run.json"
    old = json.loads(fp_path.read_text()) if fp_path.exists() else None
    if fresh or (old and old != fp):
        if old and old != fp:
            _progress("Settings changed since last run: re-planning outline.")
        (wd / "outline.json").unlink(missing_ok=True)
        if fresh or (old and old.get("model") != fp["model"]):
            (wd / "notes.json").unlink(missing_ok=True)
    fp_path.write_text(json.dumps(fp, indent=2))


def _check_cancel(cancel: threading.Event | None) -> None:
    if cancel is not None and cancel.is_set():
        raise PipelineCancelled("Cancelled")


def _extract_and_script(pdf_path: str, cfg: Config, workdir: str | Path,
                        progress: ProgressReporter | None,
                        cancel: threading.Event | None) -> None:
    """PDF -> script (writes paper.json, script.json, script.md)."""
    from .llm import LLMClient
    from .pdf_extract import extract_paper
    from .script import ScriptGenerator

    wd = Path(workdir)
    wd.mkdir(parents=True, exist_ok=True)
    write_run_fingerprint(wd, cfg)

    pdf = Path(pdf_path)
    _progress(f"Extracting {pdf.name}...")
    if progress is not None:
        progress.set_stage("extract", "Extracting text from PDF")
    paper = extract_paper(pdf, reporter=progress)
    (wd / "paper.json").write_text(json.dumps(asdict(paper), indent=2, ensure_ascii=False))
    _progress(f"  '{paper.title}': {paper.page_count} pages, {len(paper.sections)} sections")
    _check_cancel(cancel)

    llm = LLMClient(cfg.llm, cfg.cache_dir)
    gen = ScriptGenerator(llm, cfg, wd, progress=_progress)
    script = gen.generate(paper, reporter=progress)
    script.save(wd / "script.json")
    (wd / "script.md").write_text(script.to_markdown())
    _progress(f"Script: {script.word_count} words (~{script.word_count / cfg.script.words_per_minute:.0f} min), "
              f"{llm.usage['calls']} LLM calls, {llm.usage['prompt']}+{llm.usage['completion']} tokens")
    _progress(f"  -> {wd / 'script.md'}")


def _synthesize(script, cfg: Config, workdir: str | Path,
                progress: ProgressReporter | None,
                cancel: threading.Event | None) -> None:
    from .audio import render
    from .tts import create_backend

    wd = Path(workdir)
    _progress(f"Loading TTS backend '{cfg.tts.backend}' (device={cfg.tts.device})...")
    with create_backend(cfg.tts.backend, cfg.tts.device, **cfg.tts.options) as backend:
        _progress(f"  using device: {backend.device}")
        if progress is not None:
            progress.set_stage("audio", "Synthesizing podcast")
        res = render(script, backend, cfg.tts, wd / "podcast", Path(cfg.cache_dir).expanduser(),
                     progress=_progress, reporter=progress)
    rtf = res.synth_s / res.duration_s if res.duration_s else 0
    _progress(f"Audio: {res.duration_s / 60:.1f} min (synthesis {res.synth_s:.0f}s, RTF {rtf:.2f})")
    for p in (res.mp3, res.wav, res.srt):
        if p:
            _progress(f"  -> {p}")


def run_script(pdf_path: str, cfg: Config, workdir: str | Path,
               progress: ProgressReporter | None = None,
               cancel: threading.Event | None = None) -> None:
    """PDF -> script only (the `script` subcommand / stop-after-script)."""
    _extract_and_script(pdf_path, cfg, workdir, progress, cancel)
    if progress is not None:
        progress.done()


def run_paper(pdf_path: str, cfg: Config, workdir: str | Path,
              progress: ProgressReporter | None = None,
              cancel: threading.Event | None = None) -> None:
    """PDF -> script -> audio (the `run` subcommand / web conversion)."""
    _extract_and_script(pdf_path, cfg, workdir, progress, cancel)
    _check_cancel(cancel)
    from .script import Script
    script = Script.load(Path(workdir) / "script.json")
    _synthesize(script, cfg, workdir, progress, cancel)
    if progress is not None:
        progress.done()