"""FastAPI web server: upload a PDF, watch it become a podcast.

Each upload lives in ``LIBRARY/<paper_id>/`` holding the source PDF, the
generated script and audio, ``meta.json`` and a live ``status.json``. A single
in-process thread per paper drives :func:`paper2pod.pipeline.run_paper` and
persists status on every progress change.

Library root: env ``PAPER2POD_LIBRARY``, else ``./library``.

FastAPI/Uvicorn are only needed when this module is imported (the ``serve``
subcommand / web extra), so CLI-only usage never pays for them.
"""
from __future__ import annotations

import json
import os
import secrets
import shutil
import threading
import time
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from .config import load_config
from .pipeline import PipelineCancelled, run_paper
from .progress import ProgressReporter

LIBRARY = Path(os.environ.get("PAPER2POD_LIBRARY", "./library")).expanduser()
WEB_DIR = Path(__file__).parent / "web"

# Serving options set by the CLI's `serve` subcommand before uvicorn starts.
_CFG_PATH: str | None = None
_OVERRIDES: dict[str, object] = {}

_lock = threading.Lock()
_jobs: dict[str, threading.Thread] = {}
_cancel: dict[str, threading.Event] = {}

app = FastAPI(title="paper2pod")
app.mount("/static", StaticFiles(directory=WEB_DIR), name="static")

_STATUS_KEYS = ("paper_id", "state", "stage", "progress", "message", "error")


def set_serving_options(config_path: str | None, overrides: dict[str, object]) -> None:
    """Configure the effective config + overrides used by background workers."""
    global _CFG_PATH, _OVERRIDES
    _CFG_PATH = config_path
    _OVERRIDES = overrides


def _serving_config():
    cfg = load_config(_CFG_PATH)
    for key, val in _OVERRIDES.items():
        section, _, attr = key.partition(".")
        if val is not None:
            setattr(getattr(cfg, section), attr, val)
    return cfg


# ---------------------------------------------------------------- status I/O
def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def _status_payload(paper_id: str, *, state: str, stage: str, progress: float,
                    message: str, error: str | None) -> dict:
    payload = {"paper_id": paper_id, "state": state, "stage": stage,
               "progress": round(progress, 3), "message": message, "error": error}
    # always keep the full set of keys
    for k in _STATUS_KEYS:
        payload.setdefault(k, None)
    return payload


def _write_status(paper_id: str, **fields) -> None:
    payload = _status_payload(paper_id,
                              state=fields.get("state", "running"),
                              stage=fields.get("stage", "extract"),
                              progress=fields.get("progress", 0.0),
                              message=fields.get("message", ""),
                              error=fields.get("error"))
    _atomic_write(LIBRARY / paper_id / "status.json", json.dumps(payload, indent=2))


def _enrich_meta_from_paper(paper_id: str) -> None:
    """Once the extractor writes paper.json, promote the real paper title into meta.json.

    Executed on progress changes (and once at job end), so library entries show the
    paper's own title instead of the uploaded filename. The extractor falls back to
    the source stem (\"source\") when it finds no title; we skip that so the more
    useful filename is kept.
    """
    wd = LIBRARY / paper_id
    mp = wd / "meta.json"
    pp = wd / "paper.json"
    if not pp.is_file():
        return
    try:
        title = json.loads(pp.read_text()).get("title")
    except (OSError, ValueError, json.JSONDecodeError):
        return
    if not (isinstance(title, str) and title.strip()):
        return
    title = title.strip()
    # Re-read meta right before writing so a concurrent PATCH (tags/favorite/
    # manual rename) is not clobbered by this whole-dict write.
    # ponytail: best-effort merge; a file lock would fully serialize enrich
    # vs PATCH, which is overkill for a local single-user app.
    try:
        meta = json.loads(mp.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return
    if meta.get("title_enriched"):
        return
    enriched = title.lower() != "source" and title != meta.get("filename")
    if enriched:
        meta["title"] = title
    meta["title_enriched"] = True
    _atomic_write(mp, json.dumps(meta, indent=2))


def _make_reporter(paper_id: str) -> ProgressReporter:
    rep = ProgressReporter(stage="extract")

    def _on_change() -> None:
        _write_status(paper_id, state="running", stage=rep.stage,
                      progress=rep.progress, message=rep.message)
        _enrich_meta_from_paper(paper_id)

    rep.on_change(_on_change)
    return rep


def _worker(paper_id: str) -> None:
    wd = LIBRARY / paper_id
    rep = _make_reporter(paper_id)
    try:
        cfg = _serving_config()
        cancel = _cancel.get(paper_id)
        run_paper(str(wd / "source.pdf"), cfg, wd, progress=rep, cancel=cancel)
        _write_status(paper_id, state="done", stage="done", progress=1.0, message="Done")
    except PipelineCancelled as e:
        _write_status(paper_id, state="error", stage="finalize",
                      progress=rep.progress, message=str(e), error=str(e))
    except Exception as e:  # noqa: BLE001 - report any pipeline failure to the UI
        _write_status(paper_id, state="error", stage=rep.stage,
                      progress=rep.progress, message=str(e), error=str(e))
    finally:
        _enrich_meta_from_paper(paper_id)  # promote title even if a later stage failed
        with _lock:
            _cancel.pop(paper_id, None)
            _jobs.pop(paper_id, None)


def _start_job(paper_id: str) -> None:
    with _lock:
        cancel = _cancel.setdefault(paper_id, threading.Event())
        thread = _jobs.get(paper_id)
        if thread is not None and thread.is_alive():
            return  # already running
        t = threading.Thread(target=_worker, args=(paper_id,), daemon=True,
                             name=f"paper2pod-{paper_id}")
        _jobs[paper_id] = t
        t.start()


def _new_id() -> str:
    """A short, filesystem-safe, unique paper folder id."""
    return f"paper_{int(time.time())}_{secrets.token_hex(4)}"


def _is_pdf(filename: str, data: bytes) -> bool:
    return filename.lower().endswith(".pdf") or data[:1024].lstrip().startswith(b"%PDF")


# ------------------------------------------------------------------ endpoints
@app.get("/")
def index():
    f = WEB_DIR / "index.html"
    if not f.exists():
        raise HTTPException(404, "index.html not built yet")
    return FileResponse(f)


def _file(wd: Path, name: str):
    f = wd / name
    if not f.is_file():
        raise HTTPException(404, f"{name} not found")
    return FileResponse(f)


@app.post("/api/papers", status_code=202)
def upload_paper(pdf: UploadFile | None = File(default=None)):
    if pdf is None or not pdf.filename:
        raise HTTPException(400, "No file uploaded")
    data = pdf.file.read()
    if not _is_pdf(pdf.filename, data):
        raise HTTPException(400, "Upload must be a PDF file")
    paper_id = _new_id()
    wd = LIBRARY / paper_id
    wd.mkdir(parents=True, exist_ok=True)
    (wd / "source.pdf").write_bytes(data)
    created = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    meta = {"id": paper_id, "title": pdf.filename, "filename": pdf.filename,
            "created_iso": created, "bytes": len(data)}
    _atomic_write(wd / "meta.json", json.dumps(meta, indent=2))
    _write_status(paper_id, state="queued", stage="extract", progress=0.0, message="Queued")
    _start_job(paper_id)
    return JSONResponse({"id": paper_id}, status_code=202)


def _library_entry(wd: Path, meta: dict, meta_ok: bool, status: dict) -> dict:
    """Build one /api/library item shape from a paper dir's meta + status."""
    entry = {
        "id": meta.get("id", wd.name),
        "title": meta.get("title") if meta_ok else wd.name,
        "filename": meta.get("filename"),
        "has_pdf": (wd / "source.pdf").is_file(),
        "has_script": (wd / "script.json").is_file(),
        "has_audio": (wd / "podcast.mp3").is_file(),
        "created_iso": meta.get("created_iso", ""),
        "state": status.get("state", "queued" if not status else "unknown"),
    }
    entry["tags"] = meta.get("tags", [])
    entry["favorite"] = meta.get("favorite", False)
    return entry


@app.get("/api/library")
def library():
    entries = []
    if LIBRARY.is_dir():
        for d in LIBRARY.iterdir():
            if not d.is_dir():
                continue
            meta, meta_ok = {}, False
            mp = d / "meta.json"
            if mp.exists():
                try:
                    meta = json.loads(mp.read_text())
                    meta_ok = True
                except json.JSONDecodeError:
                    meta = {}
            status = {}
            sp = d / "status.json"
            if sp.exists():
                try:
                    status = json.loads(sp.read_text())
                except json.JSONDecodeError:
                    status = {}
            entries.append(_library_entry(d, meta, meta_ok, status))
    entries.sort(key=lambda e: e["created_iso"], reverse=True)
    return entries


@app.get("/api/papers/{paper_id}/status")
def paper_status(paper_id: str):
    sp = LIBRARY / paper_id / "status.json"
    if sp.exists():
        try:
            payload = json.loads(sp.read_text())
            for k in _STATUS_KEYS:
                payload.setdefault(k, None)
            return payload
        except json.JSONDecodeError:
            return {"state": "missing"}
    return {"state": "missing"}


@app.get("/api/papers/{paper_id}/audio")
def paper_audio(paper_id: str):
    mp3 = LIBRARY / paper_id / "podcast.mp3"
    if mp3.is_file():
        return FileResponse(mp3)
    raise HTTPException(404, "audio not found")


_KINDS = {"pdf": "source.pdf", "srt": "podcast.srt", "script": "script.md"}


@app.get("/api/papers/{paper_id}/file")
def paper_file(paper_id: str, kind: str):
    name = _KINDS.get(kind)
    if name is None:
        raise HTTPException(400, f"unknown kind '{kind}' (use pdf|srt|script)")
    return _file(LIBRARY / paper_id, name)


@app.patch("/api/papers/{paper_id}/meta")
async def update_paper_meta(paper_id: str, request: Request):
    """Merge a subset of {title, tags, favorite} into the paper's meta.json.

    ``title`` also marks ``title_enriched`` so the extractor never overwrites a
    manual rename. Returns the same library-item shape as /api/library.
    """
    wd = LIBRARY / paper_id
    mp = wd / "meta.json"
    if not (wd.is_dir() and mp.is_file()):
        raise HTTPException(404, "paper not found")
    raw = await request.body()
    try:
        updates = json.loads(raw) if raw else {}
    except (json.JSONDecodeError, ValueError):
        raise HTTPException(400, "invalid JSON body")
    if not isinstance(updates, dict):
        raise HTTPException(400, "body must be a JSON object")

    meta = json.loads(mp.read_text())
    if "title" in updates:
        if not isinstance(updates["title"], str):
            raise HTTPException(400, "'title' must be a string")
        meta["title"] = updates["title"]
        meta["title_enriched"] = True  # keep the extractor from overwriting the rename
    if "tags" in updates:
        tags = updates["tags"]
        if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
            raise HTTPException(400, "'tags' must be an array of strings")
        meta["tags"] = tags
    if "favorite" in updates:
        if not isinstance(updates["favorite"], bool):
            raise HTTPException(400, "'favorite' must be a boolean")
        meta["favorite"] = updates["favorite"]

    _atomic_write(mp, json.dumps(meta, indent=2))

    status = {}
    sp = wd / "status.json"
    if sp.exists():
        try:
            status = json.loads(sp.read_text())
        except json.JSONDecodeError:
            status = {}
    return _library_entry(wd, meta, True, status)


@app.post("/api/papers/{paper_id}/rerun", status_code=202)
def rerun_paper(paper_id: str):
    wd = LIBRARY / paper_id
    if not (wd / "source.pdf").is_file():
        raise HTTPException(404, "paper not found")
    with _lock:
        running = (_jobs.get(paper_id) is not None and _jobs[paper_id].is_alive())
    if running:
        return JSONResponse({"id": paper_id}, status_code=202)  # ignore: already running
    # clear old script + audio, keep notes/outline cache for a faster resume
    for name in ("script.json", "script.md", "podcast.wav", "podcast.mp3", "podcast.srt"):
        (wd / name).unlink(missing_ok=True)
    _write_status(paper_id, state="queued", stage="extract", progress=0.0, message="Queued")
    _start_job(paper_id)
    return JSONResponse({"id": paper_id}, status_code=202)


@app.delete("/api/papers/{paper_id}", status_code=204)
def delete_paper(paper_id: str):
    wd = LIBRARY / paper_id
    if not wd.is_dir():
        raise HTTPException(404, "paper not found")
    with _lock:
        cancel = _cancel.get(paper_id)
        running = (_jobs.get(paper_id) is not None and _jobs[paper_id].is_alive())
    if running and cancel is not None:
        cancel.set()  # coarse: checked only between pipeline stages
    shutil.rmtree(wd, ignore_errors=True)
    return None