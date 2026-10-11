"""Hardware selection: CUDA -> Apple MPS -> CPU, constrained by what the backend supports."""
from __future__ import annotations

import logging
import os

log = logging.getLogger(__name__)


def available_devices() -> list[str]:
    devs = []
    try:
        import torch  # noqa: PLC0415

        if torch.cuda.is_available():
            devs.append("cuda")
        mps = getattr(torch.backends, "mps", None)
        if mps is not None and mps.is_available():
            devs.append("mps")
        xpu = getattr(torch, "xpu", None)
        if xpu is not None and xpu.is_available():
            devs.append("xpu")
    except ImportError:
        pass
    devs.append("cpu")
    return devs


def resolve_device(requested: str, supported: tuple[str, ...]) -> str:
    avail = available_devices()
    if requested != "auto":
        if requested not in avail:
            raise RuntimeError(f"Device '{requested}' requested but available: {avail}")
        if requested not in supported:
            log.warning("Backend does not support '%s'; supported: %s", requested, supported)
        return requested
    for d in ("cuda", "mps", "xpu", "cpu"):
        if d in avail and d in supported:
            if d == "mps":
                # Some ops (e.g. in Kokoro) are not implemented on MPS; let torch fall back.
                os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
            return d
    return "cpu"
