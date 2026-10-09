"""The TTS plugin contract.

A backend turns (text, voice) into mono float32 audio at `sample_rate`. Everything
else — text normalisation, pauses, loudness, caching, encoding — is done by the
pipeline, so a new backend is usually ~40 lines. See DESIGN.md §6.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, ClassVar

import numpy as np


class TTSBackend(ABC):
    #: registry name, e.g. "kokoro"
    name: ClassVar[str] = "base"
    #: devices this backend can use, in order of preference
    supported_devices: ClassVar[tuple[str, ...]] = ("cpu",)

    def __init__(self, device: str = "cpu", **options: Any):
        self.device = device
        self.options = options

    @property
    @abstractmethod
    def sample_rate(self) -> int: ...

    @abstractmethod
    def synthesize(self, text: str, voice: str, speed: float = 1.0) -> np.ndarray:
        """Return mono float32 samples in [-1, 1] at self.sample_rate."""

    def list_voices(self) -> list[str]:
        return []

    def validate_voice(self, voice: str) -> None:
        """Raise ValueError early (before hours of synthesis) if `voice` is unusable."""
        voices = self.list_voices()
        if voices and voice not in voices:
            raise ValueError(f"[{self.name}] unknown voice '{voice}'. Known: {', '.join(voices)}")

    def cache_key(self) -> str:
        """Anything that changes the audio for identical text/voice (model id, options)."""
        return f"{self.name}:{sorted(self.options.items())}"

    def close(self) -> None:
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
