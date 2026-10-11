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
import re
import secrets
import shutil
import threading
import time
import asyncio
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from starlette.responses import StreamingResponse
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from .config import find_config, load_config
from .pipeline import PipelineCancelled, run_paper
from .progress import ProgressReporter

LIBRARY = Path(os.environ.get("PAPER2POD_LIBRARY", "./library")).expanduser()
WEB_DIR = Path(__file__).parent / "web"
# Web-managed LLM/TTS settings (used when no config.yaml is present, and merged over it).
SETTINGS_PATH = Path(os.environ.get("PAPER2POD_SETTINGS", "~/.config/paper2pod/settings.json")).expanduser()

# Settings fields the UI can edit, keyed as "<section>.<attr>".
_EDITABLE = {
    "llm": ("base_url", "api_key", "model"),
    "tts": ("backend", "device"),
}

# Serving options set by the CLI's `serve` subcommand before uvicorn starts.
_CFG_PATH: str | None = None
_OVERRIDES: dict[str, object] = {}

_lock = threading.Lock()
_jobs: dict[str, threading.Thread] = {}
_cancel: dict[str, threading.Event] = {}

# Server-Sent Event hub: status changes are pushed to open browser streams so the
# frontend never needs to poll.
_listeners: set[tuple[asyncio.AbstractEventLoop, "asyncio.Queue"] | tuple] = set()

_TERMINAL = {"done", "error"}


def _resume_unfinished() -> None:
    """After a restart, pick up papers whose worker thread died before finishing.

    Any paper with a non-terminal status is re-queued and its job restarted, so an
    interrupted conversion resumes automatically on the next boot.
    """
    if not LIBRARY.is_dir():
        return
    for wd in LIBRARY.iterdir():
        if not wd.is_dir() or not (wd / "source.pdf").is_file():
            continue
        sp = wd / "status.json"
        state = None
        if sp.exists():
            try:
                state = json.loads(sp.read_text()).get("state")
            except (OSError, ValueError):
                state = None
        if state in _TERMINAL:
            continue
        # Clear partial artifacts (the fresh run overwrites them) and restart.
        for name in ("script.json", "script.md", "podcast.wav", "podcast.mp3", "podcast.srt"):
            (wd / name).unlink(missing_ok=True)
        _write_status(wd.name, state="queued", stage="extract", progress=0.0,
                      message="Queued (resumed after restart)")
        _start_job(wd.name)


@asynccontextmanager
async def _lifespan(app: FastAPI):
    _resume_unfinished()
    yield


app = FastAPI(title="paper2pod", lifespan=_lifespan)
app.mount("/static", StaticFiles(directory=WEB_DIR), name="static")

_STATUS_KEYS = ("paper_id", "state", "stage", "progress", "message", "error")


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
    # Keep only editable fields, drop empty values.
    clean: dict[str, dict] = {}
    for section, attrs in _EDITABLE.items():
        sub = {a: settings.get(section, {}).get(a) for a in attrs}
        values = {a: v for a, v in sub.items() if isinstance(v, str) and v.strip()}
        if values:
            clean[section] = values
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(SETTINGS_PATH, json.dumps(clean, indent=2))
    return clean


def _serving_config():
    cfg = load_config(_CFG_PATH)
    # Web-managed settings only fill fields the YAML/env defaults left untouched
    # (precedence: CLI > env > YAML > web settings > hard defaults). We detect
    # "not set elsewhere" by comparing the current value to the dataclass default.
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
    _broadcast("status", payload)


def _broadcast(event: str, data: dict) -> None:
    """Push an event to every connected SSE client (thread-safe)."""
    with _lock:
        targets = list(_listeners)
    for loop, q in targets:
        try:
            loop.call_soon_threadsafe(
                q.put_nowait, f"event: {event}\ndata: {json.dumps(data)}\n\n")
        except RuntimeError:
            pass  # loop shut down; drop the client


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
    """Promote title/authors/affiliations/doi/tags from pipeline artifacts into meta.json.

    Executed on progress changes (and once at job end). The extractor writes
    ``paper.json`` (title, authors, affiliations, doi) and the script stage writes
    ``tags.json``. We copy them into the library's ``meta.json`` so library entries
    surface rich metadata; the more useful original filename is kept as the title
    fallback (``source`` stem is skipped).
    """
    wd = LIBRARY / paper_id
    mp = wd / "meta.json"
    if not mp.is_file():
        return
    # Re-read meta right before writing so a concurrent PATCH (tags/favorite/
    # manual rename) is not clobbered by this whole-dict write.
    # ponytail: best-effort merge; a file lock would fully serialize enrich
    # vs PATCH, which is overkill for a local single-user app.
    try:
        meta = json.loads(mp.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return

    pp = wd / "paper.json"
    if pp.is_file():
        try:
            info = json.loads(pp.read_text())
        except (OSError, ValueError, json.JSONDecodeError):
            info = {}
        for key in ("authors", "affiliations", "doi"):
            if meta.get(f"{key}_enriched"):
                continue  # user manually edited this — keep their value
            val = info.get(key)
            if val not in (None, "", [], {}):
                meta[key] = val
        title = info.get("title")
        if isinstance(title, str) and title.strip() and not meta.get("title_enriched"):
            if title.lower() != "source" and title != meta.get("filename"):
                meta["title"] = title.strip()
            meta["title_enriched"] = True

    tp = wd / "tags.json"
    if tp.is_file():
        try:
            auto_tags = [str(t) for t in json.loads(tp.read_text()) if str(t).strip()]
        except (ValueError, TypeError):
            auto_tags = []
        if auto_tags:
            # keep any user-added tags, then the auto ones (dedup, order preserved)
            seen: set[str] = set()
            merged: list[str] = []
            for t in (meta.get("tags", []) or []) + auto_tags:
                t = str(t).strip()
                if t and t not in seen:
                    seen.add(t)
                    merged.append(t)
            meta["tags"] = merged

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
        _enrich_meta_from_paper(paper_id)  # guarantee /library has fresh meta before "done"
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
    entry["authors"] = meta.get("authors", [])
    entry["affiliations"] = meta.get("affiliations", [])
    entry["doi"] = meta.get("doi", "")
    entry["read"] = bool(meta.get("read", False))
    entry["progress"] = float(meta.get("progress", 0) or 0)
    entry["duration"] = float(meta.get("duration", 0) or 0)
    entry["progress_ts"] = meta.get("progress_ts", "")
    return entry


@app.get("/api/settings")
def get_settings():
    """Web-managed LLM/TTS settings plus whether a config.yaml is authoritative."""
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
    """Save web-managed LLM/TTS settings. Accepts any subset; empties clear fields."""
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


@app.get("/api/papers/{paper_id}/transcript")
def paper_transcript(paper_id: str):
    """The structured script.json (segments + turns) for a styled transcript view."""
    f = LIBRARY / paper_id / "script.json"
    if not f.is_file():
        raise HTTPException(404, "transcript not found")
    return FileResponse(f)


_SRT_TIME = re.compile(r"(\d+):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d+):(\d{2}):(\d{2}),(\d{3})")


def _parse_srt(path: Path) -> list[dict]:
    """Parse a .srt file into ordered cues: {start, end, speaker, text, words}."""
    text = path.read_text(errors="ignore")
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
        body = [ln for ln in body if not re.fullmatch(r"\d+", ln)]  # drop cue index line
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


@app.get("/api/papers/{paper_id}/captions")
def paper_captions(paper_id: str):
    """Timed subtitle cues (from podcast.srt) for the custom word-tracked player."""
    srt = LIBRARY / paper_id / "podcast.srt"
    if not srt.is_file():
        return []  # no audio / captions yet
    return _parse_srt(srt)


def _render_cover(pdf: Path, out: Path) -> None:
    """Render the PDF's first page to a small PNG thumbnail (no poppler needed)."""
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
    """First-page thumbnail of the PDF, genented lazily and cached."""
    wd = LIBRARY / paper_id
    pdf = wd / "source.pdf"
    if not pdf.is_file():
        raise HTTPException(404, "paper not found")
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
    """Re-run only the PDF metadata extraction (title/authors/affiliations/doi).

    Updates paper.json + meta.json without regenerating script or audio. A
    manually-edited title (title_enriched) is left untouched.
    """
    wd = LIBRARY / paper_id
    pdf = wd / "source.pdf"
    if not pdf.is_file():
        raise HTTPException(404, "paper not found")
    from .pdf_extract import extract_paper  # noqa: PLC0415
    try:
        paper = extract_paper(pdf)
    except ValueError as e:
        raise HTTPException(400, f"could not extract metadata: {e}") from e
    _atomic_write(wd / "paper.json", json.dumps(asdict(paper), ensure_ascii=False, indent=2))
    (wd / "cover.png").unlink(missing_ok=True)  # regenerate first-page thumbnail
    try:
        _render_cover(pdf, wd / "cover.png")
    except Exception:  # noqa: BLE001 - a missing cover is non-fatal for a refresh
        pass
    _enrich_meta_from_paper(paper_id)

    mp = wd / "meta.json"
    meta = {}
    if mp.is_file():
        try:
            meta = json.loads(mp.read_text())
        except (OSError, ValueError):
            meta = {}
    sp = wd / "status.json"
    status = {}
    if sp.is_file():
        try:
            status = json.loads(sp.read_text())
        except (OSError, ValueError):
            status = {}
    return _library_entry(wd, meta, True, status)


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
            meta[f"{key}_enriched"] = True  # user override: keep on re-extraction
    if "doi" in updates:
        if not isinstance(updates["doi"], str):
            raise HTTPException(400, "'doi' must be a string")
        meta["doi"] = updates["doi"].strip()  # empty clears a wrong DOI
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