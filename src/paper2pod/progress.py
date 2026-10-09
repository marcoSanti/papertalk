"""Lightweight job progress reporting for the web server.

A ``ProgressReporter`` tracks the current pipeline stage and an overall 0..1
completion value. Library functions thread an optional reporter and call
``set_stage``/``advance``/``set_message``; the webapp installs an ``on_change``
callback that persists ``status.json`` on every update. When no reporter is
passed (the default for the CLI), nothing is emitted and there is zero overhead.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

# Overall-progress band for each stage (start..end), fixed by the web contract.
BANDS: dict[str, tuple[float, float]] = {
    "extract":  (0.00, 0.10),
    "notes":    (0.10, 0.30),
    "outline":  (0.30, 0.45),
    "segments": (0.45, 0.70),
    "audio":    (0.70, 0.95),
    "finalize": (0.95, 1.00),
}


@dataclass
class ProgressReporter:
    stage: str = "extract"
    message: str = ""
    progress: float = 0.0  # 0..1 overall
    _sub: float = field(default=0.0, init=False, repr=False)  # 0..1 within the stage
    _on_change: Callable[[], None] | None = field(default=None, init=False, repr=False)

    def on_change(self, fn: Callable[[], None] | None) -> None:
        """Install a callback invoked (synchronously) whenever progress changes."""
        self._on_change = fn

    def _emit(self) -> None:
        if self._on_change is not None:
            self._on_change()

    def set_stage(self, name: str, message: str = "") -> None:
        """Move to a new stage, resetting the within-stage progress."""
        self.stage = name
        self._sub = 0.0
        self.message = message
        self._recompute()

    def advance(self, sub_frac: float) -> None:
        """Set within-stage progress to an absolute 0..1 fraction."""
        self._sub = min(1.0, max(0.0, sub_frac))
        self._recompute()

    def set_message(self, msg: str) -> None:
        self.message = msg
        self._emit()

    def _recompute(self) -> None:
        start, end = BANDS.get(self.stage, (0.0, 1.0))
        self.progress = start + self._sub * (end - start)
        self._emit()

    def done(self) -> None:
        self.stage = "done"
        self.message = "Done"
        self.progress = 1.0
        self._emit()

    def fail(self, message: str) -> None:
        self.stage = "finalize"
        self.message = message
        self._emit()