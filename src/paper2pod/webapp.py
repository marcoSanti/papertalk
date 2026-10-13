"""Single-process webapp: upload a PDF, watch it become a podcast.

Everything runs on this machine (loopback-only HTTP for the in-page UI). Each
upload lives in the *store* (a local folder or a Samba/NAS share, see
:mod:`paper2pod.store`) under ``<paper_id>/`` holding the source PDF, the
generated script+audio, ``meta.json`` and a live ``status.json``. A single
in-process thread per paper drives :func:`paper2pod.pipeline.run_paper`
(pdf -> script -> audio, with local TTS) and persists status on every change.

No remote interface, no client/server split: the FastAPI app is only an
embedded server serving the local UI over 127.0.0.1.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
import asyncio
import logging
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from starlette.responses import StreamingResponse
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from .config import find_config, load_config
from .pipeline import PipelineCancelled, run_paper
from .progress import ProgressReporter
from .store import LocalStore, make_store

log = logging.getLogger(__name__)

WEB_DIR = Path(__file__).parent / "web"
# Web-managed LLM/TTS settings (used when no config.yaml is present, merged over it).
SETTINGS_PATH = Path(os.environ.get("PAPER2POD_SETTINGS", "~/.config/paper2pod/settings.json")).expanduser()

# The effective storage backend, built from config at boot. LocalStore is the
# default and is what tests exercise; SMBStore mirrors to a NAS behind it.
def _bootstrap_config():
    # Build a bare config just to resolve storage early (called before the app
    # fully wires settings). Deterministic from env at import time.
    return load_config(None)


STORE: LocalStore = make_store(_bootstrap_config())


# Settings fields the UI can edit, keyed as "<section>.<attr>".
_EDITABLE = {
    "llm": ("base_url", "api_key", "model"),
    "tts": ("backend", "device"),
}

# Serving options set by the CLI before uvicorn starts.
_CFG_PATH: str | None = None
_OVERRIDES: dict[str, object] = {}

_lock = threading.Lock()
_jobs: dict[str, threading.Thread] = {}
_cancel: dict[str, threading.Event] = {}

# Server-Sent Event hub: status changes are pushed to open UI streams.
_listeners: set[tuple[asyncio.AbstractEventLoop, "asyncio.Queue"] | tuple] = set()

_TERMINAL = {"done", "error"}


def set_serving_options(config_path: str | None, overrides: dict[str, object]) -> None:
    """Configure the effective config + overrides used by background workers."""
    global _CFG_PATH, _OVERRIDES
    _CFG_PATH = config_path
    _OVERRIDES = overrides


def _load_settings() -> dict:
    if SETTINGS_PATH.is_file():
        try:
            s = json.loads(SETTINGS_PATH.read_text())
            if isinstance(s, dict):
                return s
        except (OSError, ValueError):
            pass
    return {}


def _save_settings(settings: dict) -> None:
    clean: dict[str, dict] = {}
    for section, attrs in _EDITABLE.items():
        sub = {a: settings.get(section, {}).get(a) for a in attrs}
        values = {a: v for a, v in sub.items() if isinstance(v, str) and v.strip()}
        if values:
            clean[section] = values
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(SETTINGS_PATH, json.dumps(clean, indent=2).encode())
    return clean


def _serving_config():
    cfg = load_config(_CFG_PATH)
    from dataclasses import fields as dc_fields
    for section, sub in _load_settings().items():
        obj = getattr(cfg, section, None)
        if obj is None:
            continue
        default_obj = type(obj)()
        for attr, val in sub.items():
            if not hasattr(obj, attr) or val in (None, ""):
                continue
            if getattr(obj, attr) != getattr(default_obj, attr):
                continue  # already set by env/YAML/CLI — don't clobber
            setattr(obj, attr, val)
    for key, val in _OVERRIDES.items():
        section, _, attr = key.partition(".")
        if val is not None:
            setattr(getattr(cfg, section), attr, val)
    return cfg


# ---------------------------------------------------------------- status I/O
def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


_STATUS_KEYS = ("paper_id", "state", "stage", "progress", "message", "error")


def _status_payload(paper_id: str, *, state: str, stage: str, progress: float,
                    message: str, error: str | None) -> dict:
    payload = {"paper_id": paper_id, "state": state, "stage": stage,
               "progress": round(progress, 3), "message": message, "error": error}
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
    STORE.write_json(f"{paper_id}/status.json", payload)
    _broadcast("status", payload)


def _broadcast(event: str, data: dict) -> None:
    with _lock:
        targets = list(_listeners)
    for loop, q in targets:
        try:
            loop.call_soon_threadsafe(
                q.put_nowait, f"event: {event}\ndata: {json.dumps(data)}\n\n")
        except RuntimeError:
            pass  # loop shut down; drop the client


app = FastAPI(title="paper2pod")
app.mount("/static", StaticFiles(directory=WEB_DIR), name="static")


@app.get("/")
def index():
    f = WEB_DIR / "index.html"
    if not f.exists():
        raise HTTPException(404, "index.html not built yet")
    return HTMLResponse(f.read_text().replace(
        "<head>", '<head><base href="/static/">', 1))


@app.get("/api/events")
async def sse_stream(request: Request):
    """Single long-lived stream that pushes status changes as they happen."""
    loop = asyncio.get_running_loop()
    q: asyncio.Queue = asyncio.Queue()
    with _lock:
        _listeners.add((loop, q))

    async def gen():
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    msg = q.get_nowait()
                except asyncio.QueueEmpty:
                    yield ": keepalive\n\n"
                    await asyncio.sleep(15)
                    continue
                yield msg
        finally:
            with _lock:
                _listeners.discard((loop, q))

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store"})


def _enrich_meta_from_paper(paper_id: str) -> None:
    """Promote title/authors/affiliations/doi/tags from pipeline artifacts into meta.json."""
    rel = f"{paper_id}/meta.json"
    mp = STORE.local_path(rel)
    if not STORE.exists(rel):
        return
    try:
        meta = STORE.read_json(rel)
    except (OSError, ValueError, json.JSONDecodeError):
        return

    pp = f"{paper_id}/paper.json"
    if STORE.exists(pp):
        info = STORE.read_json(pp)
        for key in ("authors", "affiliations", "doi"):
            if meta.get(f"{key}_enriched"):
                continue
            val = info.get(key)
            if val not in (None, "", [], {}):
                meta[key] = val
        title = info.get("title")
        if isinstance(title, str) and title.strip() and not meta.get("title_enriched"):
            if title.lower() != "source" and title != meta.get("filename"):
                meta["title"] = title.strip()
            meta["title_enriched"] = True

    tp = f"{paper_id}/tags.json"
    if STORE.exists(tp):
        try:
            auto_tags = [str(t) for t in STORE.read_json(tp) if str(t).strip()]
        except (ValueError, TypeError):
            auto_tags = []
        if auto_tags:
            seen: set[str] = set()
            merged: list[str] = []
            for t in (meta.get("tags", []) or []) + auto_tags:
                t = str(t).strip()
                if t and t not in seen:
                    seen.add(t)
                    merged.append(t)
            meta["tags"] = merged

    STORE.write_json(rel, meta)


def _make_reporter(paper_id: str) -> ProgressReporter:
    rep = ProgressReporter(stage="extract")

    def _on_change() -> None:
        _write_status(paper_id, state="running", stage=rep.stage,
                      progress=rep.progress, message=rep.message)
        _enrich_meta_from_paper(paper_id)

    rep.on_change(_on_change)
    return rep


def _worker(paper_id: str) -> None:
    wd = STORE.local_path(paper_id)  # local dir the pipeline works on
    wd.mkdir(parents=True, exist_ok=True)
    rep = _make_reporter(paper_id)
    try:
        cfg = _serving_config()
        try:
            meta = STORE.read_json(f"{paper_id}/meta.json")
            if meta.get("depth") in ("summary", "in_depth", "custom"):
                cfg.script.depth = meta["depth"]
                cfg.script.depth_note = meta.get("depth_note", "")
        except (OSError, ValueError):
            pass
        cancel = _cancel.get(paper_id)
        # The FULL pipeline runs here, on this machine: pdf -> script -> audio
        # (local TTS). No client/server handoff.
        run_paper(str(wd / "source.pdf"), cfg, wd, progress=rep, cancel=cancel)
        _enrich_meta_from_paper(paper_id)  # fresh meta before "done"
        _finalize(paper_id)
    except PipelineCancelled as e:
        _write_status(paper_id, state="error", stage="finalize",
                      progress=rep.progress, message=str(e), error=str(e))
    except Exception as e:  # noqa: BLE001 - report any pipeline failure to the UI
        _write_status(paper_id, state="error", stage=rep.stage,
                      progress=rep.progress, message=str(e), error=str(e))
    finally:
        _enrich_meta_from_paper(paper_id)
        with _lock:
            _cancel.pop(paper_id, None)
            _jobs.pop(paper_id, None)


def _finalize(paper_id: str) -> None:
    """Mark done and (for SMB) push finished artifacts to the share."""
    wd = STORE.local_path(paper_id)
    mp3 = wd / "podcast.mp3"
    duration = 0.0
    if mp3.is_file():
        duration = _probe_duration(mp3)
        if duration and duration > 0:
            rel = f"{paper_id}/meta.json"
            if STORE.exists(rel):
                meta = STORE.read_json(rel)
                meta["duration"] = round(duration, 1)
                STORE.write_json(rel, meta)
    # SMB backend: push the whole paper dir up so the NAS holds the result.
    _push_paper(paper_id)
    _write_status(paper_id, state="done", stage="done", progress=1.0, message="Done")


def _push_paper(paper_id: str) -> None:
    """Best-effort upload of a paper's local artifacts to the store (SMB only)."""
    if isinstance(STORE, LocalStore):
        return
    wd = STORE.local_path(paper_id)
    if not wd.is_dir():
        return
    for p in ["source.pdf", "paper.json", "script.json", "script.md",
              "notes.json", "outline.json", "run.json", "tags.json",
              "meta.json", "status.json", "podcast.wav", "podcast.mp3",
              "podcast.srt", "cover.png"]:
        f = wd / p
        if f.is_file():
            try:
                STORE.write_bytes(f"{paper_id}/{p}", f.read_bytes())
            except Exception as e:  # noqa: BLE001
                log.warning("push %s failed: %s", p, e)


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
    return f"paper_{int(time.time())}_{secrets_token_hex(4)}"


def secrets_token_hex(n: int) -> str:
    import secrets  # noqa: PLC0415
    return secrets.token_hex(n)


def _is_pdf(filename: str, data: bytes) -> bool:
    return filename.lower().endswith(".pdf") or data[:1024].lstrip().startswith(b"%PDF")


def _resume_unfinished() -> None:
    """Re-queue papers whose worker thread died before finishing."""

    def _walk():
        for pid in STORE.iterdir(""):
            if not pid.startswith("paper_"):
                continue
            rel = f"{pid}/status.json"
            if not STORE.exists(rel):
                continue
            state = STORE.read_json(rel).get("state")
            yield pid, state

    for pid, state in _walk():
        if state in _TERMINAL:
            continue
        for name in ("script.json", "script.md", "podcast.wav", "podcast.mp3", "podcast.srt"):
            STORE.unlink(f"{pid}/{name}")
        _write_status(pid, state="queued", stage="extract", progress=0.0,
                      message="Queued (resumed after restart)")
        _start_job(pid)


@asynccontextmanager
async def _lifespan(app: FastAPI):
    _resume_unfinished()
    yield


app.router.lifespan_context = _lifespan


def _file(wd: Path, name: str):
    f = wd / name
    if not f.is_file():
        raise HTTPException(404, f"{name} not found")
    return FileResponse(f)


@app.post("/api/papers", status_code=202)
def upload_paper(pdf: UploadFile | None = File(default=None),
                 depth: str = Form(default="in_depth"),
                 depth_note: str = Form(default="")):
    if pdf is None or not pdf.filename:
        raise HTTPException(400, "No file uploaded")
    data = pdf.file.read()
    if not _is_pdf(pdf.filename, data):
        raise HTTPException(400, "Upload must be a PDF file")
    if depth not in ("summary", "in_depth", "custom"):
        raise HTTPException(422, "depth must be summary | in_depth | custom")
    paper_id = _new_id()
    wd = STORE.local_path(paper_id)
    wd.mkdir(parents=True, exist_ok=True)
    created = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    meta = {"id": paper_id, "title": pdf.filename, "filename": pdf.filename,
            "created_iso": created, "bytes": len(data),
            "depth": depth, "depth_note": depth_note.strip()}
    STORE.write_json(f"{paper_id}/meta.json", meta)
    STORE.write_bytes(f"{paper_id}/source.pdf", data)
    _write_status(paper_id, state="queued", stage="extract", progress=0.0, message="Queued")
    _start_job(paper_id)
    return JSONResponse({"id": paper_id}, status_code=202)


def _library_entry(pid: str) -> dict:
    """Build one /api/library item shape from a paper dir's meta + status."""
    rel = f"{pid}/meta.json"
    meta, meta_ok = {}, False
    if STORE.exists(rel):
        try:
            meta = STORE.read_json(rel)
            meta_ok = True
        except json.JSONDecodeError:
            meta = {}
    status = {}
    srel = f"{pid}/status.json"
    if STORE.exists(srel):
        try:
            status = STORE.read_json(srel)
        except json.JSONDecodeError:
            status = {}
    lpath = STORE.local_path(pid)
    entry = {
        "id": meta.get("id", pid),
        "title": meta.get("title") if meta_ok else pid,
        "filename": meta.get("filename"),
        "has_pdf": (lpath / "source.pdf").is_file(),
        "has_script": (lpath / "script.json").is_file(),
        "has_audio": (lpath / "podcast.mp3").is_file(),
        "created_iso": meta.get("created_iso", ""),
        "state": status.get("state", "queued" if not status else "unknown"),
    }
    entry["tags"] = meta.get("tags", [])
    entry["favorite"] = meta.get("favorite", False)
    entry["authors"] = meta.get("authors", [])
    entry["affiliations"] = meta.get("affiliations", [])
    entry["doi"] = meta.get("doi", "")
    entry["read"] = bool(meta.get("read", False))
    entry["depth"] = meta.get("depth", "in_depth")
    entry["progress"] = float(meta.get("progress", 0) or 0)
    entry["duration"] = float(meta.get("duration", 0) or 0)
    entry["progress_ts"] = meta.get("progress_ts", "")
    entry["stage"] = status.get("stage")
    entry["message"] = status.get("message")
    entry["status_error"] = status.get("error")
    s_prog = status.get("progress")
    if isinstance(s_prog, (int, float)) and not (s_prog == 0 and entry["duration"] == 0):
        entry["progress"] = float(s_prog)
    return entry


@app.get("/api/settings")
def get_settings():
    cfg = _serving_config()
    return {
        "config_file": find_config(_CFG_PATH) is not None,
        "applied": {
            "llm": {"base_url": cfg.llm.base_url, "model": cfg.llm.model,
                    "api_key": bool(cfg.llm.api_key)},
            "tts": {"backend": cfg.tts.backend, "device": cfg.tts.device},
        },
        "editable": _load_settings(),
        "edit_fields": {s: list(a) for s, a in _EDITABLE.items()},
    }


@app.put("/api/settings")
async def put_settings(request: Request):
    raw = await request.body()
    try:
        body = json.loads(raw) if raw else {}
    except (json.JSONDecodeError, ValueError):
        raise HTTPException(400, "invalid JSON body") from None
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be a JSON object") from None
    current = _load_settings()
    for section, attrs in _EDITABLE.items():
        sub = body.get(section)
        if not isinstance(sub, dict):
            continue
        current.setdefault(section, {})
        for attr in attrs:
            val = sub.get(attr)
            if isinstance(val, str):
                current[section][attr] = val.strip()
    clean = _save_settings(current)
    return {"config_file": find_config(_CFG_PATH) is not None, "editable": clean}


@app.get("/api/library")
def library(limit: int = 0, offset: int = 0):
    entries = [_library_entry(pid) for pid in STORE.iterdir("")
               if pid.startswith("paper_")]
    entries.sort(key=lambda e: e["created_iso"], reverse=True)
    if limit and limit > 0:
        total = len(entries)
        entries = entries[offset:offset + limit]
        return {"entries": entries, "total": total, "offset": offset, "limit": limit}
    return entries


@app.get("/api/papers/{paper_id}/status")
def paper_status(paper_id: str):
    rel = f"{paper_id}/status.json"
    if STORE.exists(rel):
        try:
            payload = STORE.read_json(rel)
            for k in _STATUS_KEYS:
                payload.setdefault(k, None)
            return payload
        except json.JSONDecodeError:
            return {"state": "missing"}
    return {"state": "missing"}


def _paper_wd(paper_id: str, require: bool = True) -> Path:
    wd = STORE.local_path(paper_id)
    if require and not (wd / "source.pdf").is_file():
        raise HTTPException(404, "paper not found")
    return wd


@app.get("/api/papers/{paper_id}/audio")
def paper_audio(paper_id: str):
    mp3 = _paper_wd(paper_id) / "podcast.mp3"
    if mp3.is_file():
        return FileResponse(mp3)
    raise HTTPException(404, "audio not found")


@app.get("/api/papers/{paper_id}/transcript")
def paper_transcript(paper_id: str):
    f = _paper_wd(paper_id) / "script.json"
    if not f.is_file():
        raise HTTPException(404, "transcript not found")
    return FileResponse(f)


@app.get("/api/papers/{paper_id}/captions")
def paper_captions(paper_id: str):
    srt = _paper_wd(paper_id) / "podcast.srt"
    if not srt.is_file():
        return []
    return _parse_srt(srt)


def _render_cover(pdf: Path, out: Path) -> None:
    import pymupdf  # noqa: PLC0415
    doc = pymupdf.open(str(pdf))
    if not doc.page_count:
        raise ValueError("PDF has no pages")
    page = doc.load_page(0)
    width = page.rect.width
    scale = 400.0 / width if width else 2.0
    pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False)
    pix.save(str(out))


@app.get("/api/papers/{paper_id}/cover")
def paper_cover(paper_id: str):
    wd = _paper_wd(paper_id)
    pdf = wd / "source.pdf"
    cover = wd / "cover.png"
    if not cover.is_file():
        try:
            _render_cover(pdf, cover)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(500, f"could not render cover: {e}") from e
    return FileResponse(cover, media_type="image/png",
                        headers={"Cache-Control": "no-store"})


@app.post("/api/papers/{paper_id}/refresh-meta")
def refresh_paper_meta(paper_id: str):
    wd = _paper_wd(paper_id)
    pdf = wd / "source.pdf"
    from .pdf_extract import extract_paper  # noqa: PLC0415
    try:
        paper = extract_paper(pdf)
    except ValueError as e:
        raise HTTPException(400, f"could not extract metadata: {e}") from e
    STORE.write_json(f"{paper_id}/paper.json", asdict(paper))
    (wd / "cover.png").unlink(missing_ok=True)
    try:
        _render_cover(pdf, wd / "cover.png")
    except Exception:  # noqa: BLE001
        pass
    _enrich_meta_from_paper(paper_id)
    if not isinstance(STORE, LocalStore):
        for n in ("paper.json", "cover.png"):
            p = wd / n
            if p.is_file():
                try:
                    STORE.write_bytes(f"{paper_id}/{n}", p.read_bytes())
                except Exception:  # noqa: BLE001
                    pass
    return _library_entry(paper_id)


_KINDS = {"pdf": "source.pdf", "srt": "podcast.srt", "script": "script.md"}


@app.get("/api/papers/{paper_id}/file")
def paper_file(paper_id: str, kind: str):
    name = _KINDS.get(kind)
    if name is None:
        raise HTTPException(400, f"unknown kind '{kind}' (use pdf|srt|script)")
    wd = _paper_wd(paper_id)
    return _file(wd, name)


@app.patch("/api/papers/{paper_id}/meta")
async def update_paper_meta(paper_id: str, request: Request):
    rel = f"{paper_id}/meta.json"
    wd = STORE.local_path(paper_id)
    if not (wd.is_dir() and STORE.exists(rel)):
        raise HTTPException(404, "paper not found")
    raw = await request.body()
    try:
        updates = json.loads(raw) if raw else {}
    except (json.JSONDecodeError, ValueError):
        raise HTTPException(400, "invalid JSON body")
    if not isinstance(updates, dict):
        raise HTTPException(400, "body must be a JSON object")

    meta = STORE.read_json(rel)
    if "title" in updates:
        if not isinstance(updates["title"], str):
            raise HTTPException(400, "'title' must be a string")
        meta["title"] = updates["title"]
        meta["title_enriched"] = True
    if "tags" in updates:
        tags = updates["tags"]
        if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
            raise HTTPException(400, "'tags' must be an array of strings")
        meta["tags"] = tags
    if "favorite" in updates:
        if not isinstance(updates["favorite"], bool):
            raise HTTPException(400, "'favorite' must be a boolean")
        meta["favorite"] = updates["favorite"]
    if "read" in updates:
        if not isinstance(updates["read"], bool):
            raise HTTPException(400, "'read' must be a boolean")
        meta["read"] = updates["read"]
    if "filename" in updates:
        if not isinstance(updates["filename"], str):
            raise HTTPException(400, "'filename' must be a string")
        meta["filename"] = updates["filename"].strip() or meta.get("filename")
    for key in ("authors", "affiliations"):
        if key in updates:
            v = updates[key]
            if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):
                raise HTTPException(400, f"'{key}' must be an array of strings")
            meta[key] = [s for s in v if s.strip()]
            meta[f"{key}_enriched"] = True
    if "doi" in updates:
        if not isinstance(updates["doi"], str):
            raise HTTPException(400, "'doi' must be a string")
        meta["doi"] = updates["doi"].strip()
        meta["doi_enriched"] = True
    progress_changed = "progress" in updates or "duration" in updates
    if "progress" in updates:
        if not isinstance(updates["progress"], (int, float)) or updates["progress"] < 0:
            raise HTTPException(400, "'progress' must be a non-negative number")
        meta["progress"] = round(float(updates["progress"]), 1)
    if "duration" in updates:
        if isinstance(updates["duration"], (int, float)) and updates["duration"] > 0:
            meta["duration"] = round(float(updates["duration"]), 1)
    if progress_changed:
        meta["progress_ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    STORE.write_json(rel, meta)
    return _library_entry(paper_id)


@app.post("/api/papers/{paper_id}/rerun", status_code=202)
def rerun_paper(paper_id: str):
    if not (STORE.local_path(paper_id) / "source.pdf").is_file():
        raise HTTPException(404, "paper not found")
    with _lock:
        running = (_jobs.get(paper_id) is not None and _jobs[paper_id].is_alive())
    if running:
        return JSONResponse({"id": paper_id}, status_code=202)
    for name in ("script.json", "script.md", "podcast.wav", "podcast.mp3", "podcast.srt"):
        STORE.unlink(f"{paper_id}/{name}")
    _write_status(paper_id, state="queued", stage="extract", progress=0.0, message="Queued")
    _start_job(paper_id)
    return JSONResponse({"id": paper_id}, status_code=202)


@app.delete("/api/papers/{paper_id}", status_code=204)
def delete_paper(paper_id: str):
    if not (STORE.local_path(paper_id) / "source.pdf").is_file():
        raise HTTPException(404, "paper not found")
    with _lock:
        cancel = _cancel.get(paper_id)
        running = (_jobs.get(paper_id) is not None and _jobs[paper_id].is_alive())
    if running and cancel is not None:
        cancel.set()
    STORE.rmtree(paper_id)
    return None


# ----------------------------------------------------------- srt parsing
_SRT_TIME = re.compile(r"(\d+):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d+):(\d{2}):(\d{2}),(\d{3})")


def _parse_srt(path: Path) -> list[dict]:
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return []
    chunks = [c for c in re.split(r"\n\s*\n", text) if c]
    cues: list[dict] = []
    for chunk in chunks:
        tm = re.search(_SRT_TIME, chunk)
        if not tm:
            continue
        h, mm, s, ms = (int(tm.group(i)) for i in range(1, 5))
        h2, mm2, s2, ms2 = (int(tm.group(i)) for i in range(5, 9))
        body = re.sub(_SRT_TIME, "", chunk).splitlines()
        body = [ln.strip() for ln in body if ln.strip()]
        body = [ln for ln in body if not re.fullmatch(r"\d+", ln)]
        speaker, text = "", " ".join(body).strip()
        if text:
            sp = re.match(r"^(.+?):\s*(.*)$", text)
            if sp:
                speaker, text = sp.group(1).strip(), sp.group(2).strip()
        cues.append({"start": h * 3600 + mm * 60 + s + ms / 1000,
                     "end": h2 * 3600 + mm2 * 60 + s2 + ms2 / 1000,
                     "speaker": speaker, "text": text,
                     "words": re.findall(r"\S+", text)})
    return cues


def _probe_duration(mp3: Path) -> float:
    try:
        import soundfile as sf
        info = sf.info(str(mp3))
        if info and getattr(info, "duration", 0):
            return float(info.duration)
    except Exception:  # noqa: BLE001
        pass
    try:
        import subprocess
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=noprint_wrappers=1:nokey=1", str(mp3)],
                             capture_output=True, text=True, timeout=30)
        return float(out.stdout.strip())
    except Exception:  # noqa: BLE001
        return 0.0