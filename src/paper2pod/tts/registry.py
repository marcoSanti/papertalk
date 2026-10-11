"""Backend discovery. Three ways to provide a backend:

1. Built-in name:            tts.backend: kokoro
2. Installed plugin package: registers an entry point in group "paper2pod.tts"
3. Import path:              tts.backend: "my_module:MyBackend"  (file on PYTHONPATH)
"""
from __future__ import annotations

import threading
import importlib
from importlib.metadata import entry_points

from .base import TTSBackend
from .device import resolve_device

BUILTIN = {
    "kokoro": "paper2pod.tts.kokoro_backend:KokoroBackend",
    "openai_http": "paper2pod.tts.openai_http:OpenAIHTTPBackend",
    "null": "paper2pod.tts.null_backend:NullBackend",
}
GROUP = "paper2pod.tts"


def _load(path: str) -> type[TTSBackend]:
    mod, _, attr = path.partition(":")
    cls = getattr(importlib.import_module(mod), attr)
    if not (isinstance(cls, type) and issubclass(cls, TTSBackend)):
        raise TypeError(f"{path} is not a TTSBackend subclass")
    return cls


def available_backends() -> dict[str, str]:
    found = dict(BUILTIN)
    for ep in entry_points(group=GROUP):
        found.setdefault(ep.name, ep.value)
    return found


# Process-wide backend cache: one model (and its voices) is loaded once and reused by
# every job, so heavy model files / voice weights aren't re-validated against HF per
# conversion (a single KModel is ~a few GB load otherwise).
_BACKENDS: dict[tuple, TTSBackend] = {}
_backend_lock = threading.Lock()


def create_backend(name: str, device: str = "auto", **options) -> TTSBackend:
    if ":" in name:
        cls = _load(name)
    else:
        backends = available_backends()
        if name not in backends:
            raise KeyError(f"Unknown TTS backend '{name}'. Available: {', '.join(backends)}")
        cls = _load(backends[name])
    dev = resolve_device(device, cls.supported_devices)
    key = (name, dev, tuple(sorted(options.items())))
    with _backend_lock:
        cached = _BACKENDS.get(key)
        if cached is not None:
            return cached
        backend = cls(device=dev, **options)
        _BACKENDS[key] = backend
        return backend
