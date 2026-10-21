#!/usr/bin/env python3
"""paper2pod-storage — a pure file-storage HTTP server.

Deliberately tiny: it only stores and serves files over HTTP. No compute, no
SMB, no pipeline. Papers are stored as a flat key->bytes map under a root
dir; the app does everything else (see client/.../Storage.swift, `HttpStorage`).

Options:
    PAPER2POD_STORAGE_PORT  (default 9170)
    PAPER2POD_STORAGE_ROOT  (default ~/.paper2pod/storage)
    PAPER2POD_STORAGE_TOKEN (optional; must match client token)

Routes (paths are URL-encoded; no leading slash in the wire form):
    GET  /                    -> JSON list of stored keys
    GET  /<key>               -> bytes for that key
    PUT  /<key>               -> store request body bytes under key
    DELETE /<key>             -> remove key
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get("PAPER2POD_STORAGE_ROOT", str(Path.home() / ".paper2pod" / "storage"))).expanduser()
TOKEN = os.environ.get("PAPER2POD_STORAGE_TOKEN", "")

# In-memory index (key -> path). Rebuilt lazily by walking the root.
INDEX: dict[str, Path] = {}
INDEX_LOCK = threading.Lock()
DIRTY = True


def _key_path(key: str) -> Path:
    """The file a key is stored in."""
    # Keys are URL-safe file paths (e.g. "papers/<id>/paper.json").
    return ROOT / key


def _refresh_index() -> None:
    """Rebuild the key index from the files under ROOT."""
    global DIRTY
    INDEX.clear()
    if not ROOT.is_dir():
        return
    for dirpath, _dirs, files in Path.walk(ROOT):
        for name in files:
            f = dirpath / name
            INDEX[f.relative_to(ROOT).as_posix()] = f
    DIRTY = False


def index() -> dict[str, Path]:
    """Every stored key and its file, rebuilt from disk when marked dirty."""
    if DIRTY:
        with INDEX_LOCK:
            if DIRTY:
                _refresh_index()
    return INDEX


def store(key: str, data: bytes) -> str:
    """Write `data` under `key` atomically; returns its SHA-1."""
    with INDEX_LOCK:
        p = _key_path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, p)
        INDEX[key] = p
        DIRTY = True
        return hashlib.sha1(data).hexdigest()


def fetch(key: str) -> bytes:
    """The bytes under `key`; KeyError when there are none."""
    p = index().get(key)
    if p is None or not p.exists():
        raise KeyError(key)
    return p.read_bytes()


def delete(key: str) -> None:
    """Remove `key` (no error when it's missing)."""
    with INDEX_LOCK:
        p = _key_path(key)
        p.unlink(missing_ok=True)
        INDEX.pop(key, None)
        DIRTY = True


class Handler(BaseHTTPRequestHandler):
    """GET, PUT, DELETE and HEAD of keys, behind the optional bearer token."""
    def log_message(self, *args):  # keep it quiet
        """No per-request logging."""
        pass

    # --- helpers -------------------------------------------------------
    def _bad(self, msg, code=400):
        """A JSON error reply."""
        payload = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _ok_bytes(self, data: bytes, ctype="application/octet-stream"):
        """A 200 reply with `data`."""
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Digest", hashlib.sha1(data).hexdigest())
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        """No token configured, or the request carries it."""
        if not TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {TOKEN}"

    def _key(self) -> str | None:
        """The key named by the request path; None for the root."""
        path = urllib.parse.unquote(self.path.split("?", 1)[0]).lstrip("/")
        if path == "/" or path == "":
            return None
        # accept a bare key too (no leading slash in path already)
        return path

    # --- verbs -----------------------------------------------------------
    def do_GET(self):
        """The key list at the root, else the key's bytes."""
        if not self._authorized():
            return self._bad("unauthorized", 401)
        key = self._key()
        if key is None:
            payload = json.dumps(sorted(index().keys())).encode()
            return self._ok_bytes(payload, "application/json")
        try:
            return self._ok_bytes(fetch(key))
        except KeyError:
            return self._bad("not found", 404)

    def do_PUT(self):
        """Store the request body under the key."""
        if not self._authorized():
            return self._bad("unauthorized", 401)
        key = self._key()
        if key is None:
            return self._bad("missing key")
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        digest = store(key, body)
        return self._ok_bytes(json.dumps({"key": key, "sha1": digest}).encode(), "application/json")

    def do_DELETE(self):
        """Remove the key."""
        if not self._authorized():
            return self._bad("unauthorized", 401)
        key = self._key()
        if key is None:
            return self._bad("missing key")
        delete(key)
        return self._ok_bytes(b"{}", "application/json")

    # HEAD == GET without body (cheap existence/size check)
    def do_HEAD(self):
        """Whether the key exists, with its size."""
        if not self._authorized():
            return self._bad("unauthorized", 401)
        key = self._key()
        if key is None or key not in index():
            return self._bad("not found", 404)
        p = index()[key]
        self.send_response(200)
        self.send_header("Content-Length", str(p.stat().st_size))
        self.end_headers()


def main() -> None:
    """Serve on PAPER2POD_STORAGE_HOST:PAPER2POD_STORAGE_PORT, or run the self-test with --selftest."""
    if "--selftest" in sys.argv:
        _selftest()
        return
    port = int(os.environ.get("PAPER2POD_STORAGE_PORT", "9170"))
    host = os.environ.get("PAPER2POD_STORAGE_HOST", "0.0.0.0")
    index()
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"paper2pod storage on http://{host}:{port}  (root: {ROOT})", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def _selftest() -> None:
    """Start the server on a free port with a temp root and exercise every route with curl."""
    import tempfile
    import subprocess
    import time

    root = Path(tempfile.mkdtemp(prefix="p2p-self-"))
    port = 0
    def pick_port() -> int:
        """A free local port."""
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        return p

    port = pick_port()
    proc = subprocess.Popen(
        [sys.executable, __file__],
        env={**os.environ, "PAPER2POD_STORAGE_PORT": str(port),
             "PAPER2POD_STORAGE_ROOT": str(root)},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    base = f"http://127.0.0.1:{port}"
    try:
        _wait(base)
        _curl(base, "PUT", "/papers/p1/paper.json", b'{"a":1}')
        got = _curl(base, "GET", "/papers/p1/paper.json")
        assert got == b'{"a":1}', got
        lst = _curl(base, "GET", "/")
        assert b"papers/p1/paper.json" in lst, lst
        _curl(base, "DELETE", "/papers/p1/paper.json")
        _curl(base, "GET", "/papers/p1/paper.json", expect=404)
        print("selftest ok")
    finally:
        proc.terminate()
        proc.wait()
        import shutil
        shutil.rmtree(root, ignore_errors=True)


def _wait(base: str) -> None:
    """Wait until the server at `base` answers."""
    import urllib.request
    import time
    for _ in range(50):
        try:
            urllib.request.urlopen(base + "/", timeout=0.2)
            return
        except Exception:
            time.sleep(0.05)
    raise SystemExit("server did not start")


def _curl(base: str, method: str, path: str, data: bytes | None = None, expect: int = 200):
    """One request through curl; fails the self-test unless the status is `expect`."""
    import urllib.request
    req = urllib.request.Request(base + path, method=method,
                                 data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=2) as r:
            if r.status != expect:
                raise AssertionError(f"{method} {path}: {r.status} != {expect}")
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code != expect:
            raise AssertionError(f"{method} {path}: {e.code} != {expect}")
        return None


if __name__ == "__main__":
    sys.exit(main())