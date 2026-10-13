"""Web-server self-check: upload a sample PDF and assert the API contract schema.

These tests exercise only the web contract (upload, /api/library, /status).
No LLM is configured, so a background job fails fast to an ``error`` state or
is still ``queued`` when we read it — but the response schema is identical in
both cases.
"""
from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent))
from make_sample_pdf import build  # noqa: E402

from paper2pod import webapp  # noqa: E402

STATUS_KEYS = {"paper_id", "state", "stage", "progress", "message", "error"}
LIB_KEYS = {"id", "title", "filename", "has_pdf", "has_script", "has_audio",
            "created_iso", "state"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    lib = tmp_path / "lib"
    monkeypatch.setenv("PAPER2POD_LIBRARY", str(lib))
    monkeypatch.setenv("PAPER2POD_SETTINGS", str(tmp_path / "settings.json"))
    monkeypatch.setenv("PAPER2POD_CONFIG", "none")  # don't pick up a dev config.yaml
    for v in ("OPENWEBUI_BASE_URL", "OPENWEBUI_API_KEY", "PAPER2POD_MODEL"):
        monkeypatch.delenv(v, raising=False)
    importlib.reload(webapp)  # re-read the env-injected library root
    return TestClient(webapp.app)


@pytest.fixture
def pdf(tmp_path):
    p = tmp_path / "sample.pdf"
    build(str(p), paras_per_section=2)
    return p


def _upload(client, pdf):
    return client.post("/api/papers",
                       files={"pdf": (pdf.name, pdf.read_bytes(), "application/pdf")})


def test_rejects_missing_and_non_pdf(client):
    assert client.post("/api/papers", files={}).status_code == 400
    r = client.post("/api/papers",
                    files={"pdf": ("note.txt", b"hello", "text/plain")})
    assert r.status_code == 400
    assert r.json()["detail"]


def test_upload_depth_stored_and_validated(client, pdf, tmp_path):
    data = pdf.read_bytes()
    r = client.post("/api/papers",
                    files={"pdf": (pdf.name, data, "application/pdf")},
                    data={"depth": "custom", "depth_note": "emphasize results"})
    assert r.status_code == 202
    pid = r.json()["id"]
    import json
    meta = json.loads((tmp_path / "lib" / pid / "meta.json").read_text())
    assert meta["depth"] == "custom"
    assert meta["depth_note"] == "emphasize results"

    r = client.post("/api/papers",
                    files={"pdf": (pdf.name, data, "application/pdf")},
                    data={"depth": "bogus"})
    assert r.status_code == 422


def test_upload_and_library_schema(client, pdf):
    r = _upload(client, pdf)
    assert r.status_code == 202
    pid = r.json()["id"]
    assert isinstance(pid, str) and pid.startswith("paper_")

    # library lists the upload with the full schema
    entries = client.get("/api/library").json()
    assert entries and any(e["id"] == pid for e in entries)
    entry = next(e for e in entries if e["id"] == pid)
    assert LIB_KEYS <= entry.keys()
    assert entry["has_pdf"] is True

    # status.json has the contract schema regardless of final state
    status = client.get(f"/api/papers/{pid}/status").json()
    assert STATUS_KEYS <= status.keys()
    assert status["paper_id"] == pid
    assert status["progress"] >= 0.0 and status["progress"] <= 1.0


def test_audio_and_file_404_when_absent(client, pdf):
    pid = _upload(client, pdf).json()["id"]
    assert client.get(f"/api/papers/{pid}/audio").status_code == 404
    assert client.get(f"/api/papers/{pid}/file", params={"kind": "pdf"}).status_code == 200
    assert client.get(f"/api/papers/{pid}/file", params={"kind": "srt"}).status_code == 404
    assert client.get(f"/api/papers/{pid}/file", params={"kind": "bogus"}).status_code == 400
    assert client.get("/api/papers/missing_id/status").json() == {"state": "missing"}


def test_delete_and_rerun(client, pdf):
    pid = _upload(client, pdf).json()["id"]
    assert client.post(f"/api/papers/{pid}/rerun").status_code == 202
    assert client.delete(f"/api/papers/{pid}").status_code == 204
    assert client.get(f"/api/papers/{pid}/status").json() == {"state": "missing"}
    assert client.delete(f"/api/papers/{pid}").status_code == 404


def _seed(client, pid, meta_title, paper_title=None):
    """Write an uploaded-style entry (title=filename) plus an optional paper.json."""
    wd = webapp.STORE.local_path(pid)
    wd.mkdir(parents=True, exist_ok=True)
    (wd / "meta.json").write_text(json.dumps(
        {"id": pid, "title": meta_title, "filename": meta_title}))
    if paper_title is not None:
        (wd / "paper.json").write_text(
            json.dumps({"title": paper_title, "page_count": 4}))
    return wd


def test_library_title_promoted_from_paper(client):
    _seed(client, "paper_abc", "paper.pdf", paper_title="Deep Learning for Pod Metaphors")
    webapp._enrich_meta_from_paper("paper_abc")
    meta = json.loads((webapp.STORE.local_path("paper_abc") / "meta.json").read_text())
    assert meta["title"] == "Deep Learning for Pod Metaphors"
    assert meta["title_enriched"] is True
    # /api/library surfaces the enriched title, not the filename
    entry = next(e for e in client.get("/api/library").json() if e["id"] == "paper_abc")
    assert entry["title"] == "Deep Learning for Pod Metaphors"


def test_library_title_keeps_filename_on_useless_fallback(client):
    wd = _seed(client, "paper_src", "paper.pdf", paper_title="source")
    webapp._enrich_meta_from_paper("paper_src")
    meta = json.loads((wd / "meta.json").read_text())
    assert meta["title"] == "paper.pdf"          # useless fallback fell through
    assert meta["title_enriched"] is True        # tagged so it won't retry


def _patch_meta(client, pid, payload):
    return client.patch(f"/api/papers/{pid}/meta", json=payload)


def test_settings_roundtrip(client):
    assert client.get("/api/settings").json() == {
        "config_file": False,  # PAPER2POD_CONFIG=none in the fixture
        "applied": {"llm": {"base_url": "http://localhost:3000/api", "model": "",
                            "api_key": False},
                    "tts": {"backend": "kokoro", "device": "auto"}},
        "editable": {},
        "edit_fields": {"llm": ["base_url", "api_key", "model"],
                        "tts": ["backend", "device"]},
    }
    r = client.put("/api/settings", json={"llm": {"base_url": "http://server/api",
                                                  "api_key": "KEY", "model": "M"},
                                          "tts": {"backend": "null", "device": "cpu"}})
    assert r.status_code == 200
    assert r.json()["editable"]["llm"]["base_url"] == "http://server/api"
    # empty strings clear a field
    r2 = client.put("/api/settings", json={"llm": {"api_key": ""}})
    assert "api_key" not in r2.json()["editable"]["llm"]


def test_patch_meta_sets_tags_and_favorite(client, pdf):
    pid = _upload(client, pdf).json()["id"]
    r = _patch_meta(client, pid, {"tags": ["ml", "podcast"], "favorite": True})
    assert r.status_code == 200
    assert r.json()["tags"] == ["ml", "podcast"]
    assert r.json()["favorite"] is True

    entry = next(e for e in client.get("/api/library").json() if e["id"] == pid)
    assert entry["tags"] == ["ml", "podcast"]
    assert entry["favorite"] is True


def test_patch_meta_title_persists_through_enrichment(client):
    wd = _seed(client, "paper_ren", "paper.pdf", paper_title="Original Extract Title")
    webapp._enrich_meta_from_paper("paper_ren")
    assert json.loads((wd / "meta.json").read_text())["title"] == "Original Extract Title"

    r = _patch_meta(client, "paper_ren", {"title": "My Hand Picked Title"})
    assert r.status_code == 200
    assert r.json()["title"] == "My Hand Picked Title"

    webapp._enrich_meta_from_paper("paper_ren")  # a later job tick would run this
    meta = json.loads((wd / "meta.json").read_text())
    assert meta["title"] == "My Hand Picked Title"   # not overwritten
    assert meta["title_enriched"] is True

    entry = next(e for e in client.get("/api/library").json() if e["id"] == "paper_ren")
    assert entry["title"] == "My Hand Picked Title"


def test_patch_meta_validates_body(client, pdf):
    pid = _upload(client, pdf).json()["id"]
    assert _patch_meta(client, pid, {"tags": "not-a-list"}).status_code == 400
    assert _patch_meta(client, pid, {"tags": ["ok", 42]}).status_code == 400
    assert _patch_meta(client, pid, {"title": 123}).status_code == 400
    assert _patch_meta(client, pid, {"favorite": "yes"}).status_code == 400
    # the bad calls must not have mutated meta
    r = client.get("/api/library").json()
    entry = next(e for e in r if e["id"] == pid)
    assert entry["tags"] == [] and entry["favorite"] is False


def test_patch_meta_404_for_missing_paper(client):
    assert _patch_meta(client, "paper_ghost", {"tags": ["x"]}).status_code == 404


def test_library_pagination(client, pdf):
    ids = [_upload(client, pdf).json()["id"] for _ in range(5)]
    # no limit -> bare list (backward compatible)
    flat = client.get("/api/library").json()
    assert isinstance(flat, list) and {e["id"] for e in flat} >= set(ids)
    # with limit -> envelope, sliced desc by created_iso
    env = client.get("/api/library?limit=2").json()
    assert set(env) == {"entries", "total", "offset", "limit"}
    assert env["limit"] == 2 and env["offset"] == 0 and env["total"] >= 5
    assert len(env["entries"]) == 2
    page2 = client.get("/api/library?limit=2&offset=2").json()
    got = [e["id"] for e in env["entries"] + page2["entries"]]
    assert len(got) == len(set(got))  # no overlap between pages