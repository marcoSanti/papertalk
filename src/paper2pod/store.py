"""Library storage: a local folder or a Samba/NAS share.

The app keeps a *local working copy* of the library (a real filesystem path,
so the pipeline, ffmpeg, pymupdf and the HTTP server can all operate on disk
files without changes). ``Store`` is the thin seam between that local copy and
the durable store:

  * ``LocalStore`` — the working copy *is* the store (no sync).
  * ``SmbStore``    — the working copy is a cache; every write is also pushed
    to the SMB share, and reads lazily pull files that aren't cached.

The public methods are deliberately tiny (bytes + json + dir listing) so the
webapp never touches SMB details. Compute-heavy steps (TTS render, cover
render, PDF extraction) run against ``local_path`` and push after.
"""
from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

# Reloaded from env each boot; the local mirror the app actually works on.
DEFAULT_CACHE = Path.home() / ".cache" / "paper2pod" / "library"


class Store(Protocol):
    def read_bytes(self, rel: str) -> bytes: ...
    def write_bytes(self, rel: str, data: bytes) -> None: ...
    def exists(self, rel: str) -> bool: ...
    def is_dir(self, rel: str) -> bool: ...
    def mkdirs(self, rel: str) -> None: ...
    def iterdir(self, rel: str) -> list[str]: ...
    def unlink(self, rel: str) -> None: ...
    def rmtree(self, rel: str) -> None: ...
    def local_path(self, rel: str) -> Path: ...
    # convenience helpers built on the primitives
    def read_json(self, rel: str) -> dict: ...
    def write_json(self, rel: str, obj: dict) -> None: ...


# --------------------------------------------------------------------------
# Convenience mixin — read/write JSON on top of the byte primitives. Reused by
# both backends; nothing SMB- or local-specific here.
class JsonMixin:
    def read_json(self, rel: str) -> dict:
        raw = self.read_bytes(rel)
        try:
            obj = json.loads(raw)
            return obj if isinstance(obj, dict) else {}
        except (ValueError, json.JSONDecodeError):
            return {}

    def write_json(self, rel: str, obj: dict) -> None:
        self.write_bytes(rel, json.dumps(obj, indent=2).encode("utf-8"))


# --------------------------------------------------------------------------
class LocalStore(JsonMixin):
    """Library is a plain local folder; the working path is authoritative."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).expanduser()

    def local_path(self, rel: str) -> Path:
        return self.root / rel

    def read_bytes(self, rel: str) -> bytes:
        return (self.root / rel).read_bytes()

    def write_bytes(self, rel: str, data: bytes) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write(p, data)

    def exists(self, rel: str) -> bool:
        return (self.root / rel).exists()

    def is_dir(self, rel: str) -> bool:
        return (self.root / rel).is_dir()

    def mkdirs(self, rel: str) -> None:
        (self.root / rel).mkdir(parents=True, exist_ok=True)

    def iterdir(self, rel: str) -> list[str]:
        d = self.root / rel
        if not d.is_dir():
            return []
        return [p.name for p in d.iterdir()]

    def unlink(self, rel: str) -> None:
        p = self.root / rel
        if p.exists():
            p.unlink()

    def rmtree(self, rel: str) -> None:
        p = self.root / rel
        if p.exists():
            shutil.rmtree(p, ignore_errors=True)


# --------------------------------------------------------------------------
class SmbStore(JsonMixin):
    """Library lives on a Samba share; a local cache mirrors it.

    Write-through: ``write_bytes`` writes the local cache *and* uploads to the
    share. Reads fall back to pulling from the share when not cached. The
    mirror lives under ``cache`` so the app can still stream audio / serve
    files from disk even when the NAS is briefly unreachable.
    """

    def __init__(self, host: str, share: str, prefix: str,
                 user: str, password: str, cache: str | Path = DEFAULT_CACHE,
                 port: int = 445) -> None:
        import smbclient  # noqa: PLC0415 - lazy; only needed for SMB backend
        self._smbclient = smbclient
        cache_root = Path(cache).expanduser() / _slug(host, share, prefix)
        self.root = cache_root
        self._host = host
        self._share = share
        self._prefix = prefix.strip("/")
        self._port = int(port)
        self._creds = {"username": user, "password": password}
        self._remote = f"//{host}/{share}/{self._prefix}" if self._prefix else f"//{host}/{share}"
        smbclient.ClientConfig(require_signing=False)
        self._connected = None  # test the share lazily on first op

    def _warn(self, exc: Exception) -> None:
        # Local cache stays authoritative if the NAS is down for *reads* we
        # already have; but this is a signal to the UI on first connect.
        import logging  # noqa: PLC0415
        logging.getLogger(__name__).warning(f"SMB ({self._remote}): {exc}")

    def _remote_path(self, rel: str) -> str:
        return f"{self._remote}/{rel}"

    def _ensure_dir_remote(self, rel: str) -> None:
        parts = rel.split("/")[:-1]
        cur = self._remote
        for part in parts:
            cur = f"{cur}/{part}"
            # makedirs is idempotent; ignore benign 'already exists'
            try:
                self._smbclient.makedirs(cur, **self._creds)
            except Exception:  # noqa: BLE001
                pass

    def local_path(self, rel: str) -> Path:
        return self.root / rel

    def read_bytes(self, rel: str) -> bytes:
        lp = self.root / rel
        if lp.exists():
            return lp.read_bytes()
        rp = self._remote_path(rel)
        try:
            with self._smbclient.open_file(rp, mode="rb", **self._creds) as f:
                data = f.read()
        except Exception as e:  # noqa: BLE001
            self._warn(e)
            raise FileNotFoundError(rel) from e
        lp.parent.mkdir(parents=True, exist_ok=True)
        lp.write_bytes(data)
        return data

    def write_bytes(self, rel: str, data: bytes) -> None:
        lp = self.root / rel
        lp.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write(lp, data)
        try:
            self._ensure_dir_remote(rel)
            with self._smbclient.open_file(self._remote_path(rel), mode="wb",
                                           **self._creds) as f:
                f.write(data)
        except Exception as e:  # noqa: BLE001
            self._warn(e)

    def exists(self, rel: str) -> bool:
        return (self.root / rel).exists()

    def is_dir(self, rel: str) -> bool:
        return (self.root / rel).is_dir()

    def mkdirs(self, rel: str) -> None:
        (self.root / rel).mkdir(parents=True, exist_ok=True)
        try:
            self._ensure_dir_remote(rel)
        except Exception as e:  # noqa: BLE001
            self._warn(e)

    def iterdir(self, rel: str) -> list[str]:
        # Merge local cache names with remote share names so a NAS-only entry
        # appears before it's pulled.
        names = {p.name for p in (self.root / rel).iterdir()} if (self.root / rel).is_dir() else set()
        try:
            with self._smbclient.scandir(self._remote_path(rel), **self._creds) as it:
                names |= {e.name for e in it}
        except Exception as e:  # noqa: BLE001
            self._warn(e)
        return sorted(names)

    def unlink(self, rel: str) -> None:
        lp = self.root / rel
        if lp.exists():
            lp.unlink()
        try:
            self._smbclient.remove(self._remote_path(rel), **self._creds)
        except Exception as e:  # noqa: BLE001
            self._warn(e)

    def rmtree(self, rel: str) -> None:
        lp = self.root / rel
        if lp.exists():
            shutil.rmtree(lp, ignore_errors=True)
        try:
            self._smbclient.rmdir(self._remote_path(rel), **self._creds)
        except Exception as e:  # noqa: BLE001
            self._warn(e)


# --------------------------------------------------------------------------
def _atomic_write(path: Path, data: bytes) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os_replace(tmp, path)


def os_replace(src: Path, dst: Path) -> None:
    import os  # noqa: PLC0415
    os.replace(src, dst)


def _slug(*parts: str) -> str:
    import hashlib  # noqa: PLC0415
    joined = "_".join(parts)
    return hashlib.sha1(joined.encode("utf-8")).hexdigest()[:16]


def make_store(config) -> Store:
    """Build the store from a resolved app Config (config.storage)."""
    s = config.storage
    if s.backend == "local":
        return LocalStore(s.root)
    if s.backend == "smb":
        return SmbStore(host=s.host, share=s.share, prefix=s.path,
                        user=s.user, password=s.password, cache=s.cache)
    raise ValueError(f"unknown storage backend: {s.backend!r}")