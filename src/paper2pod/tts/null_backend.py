"""Dependency-free test backend: a soft tone whose length tracks the text (≈150 wpm).

Lets you test the full pipeline and timings without downloading any model.
"""
from __future__ import annotations

import zlib
from typing import ClassVar

import numpy as np

from .base import TTSBackend


class NullBackend(TTSBackend):
    name = "null"
    supported_devices: ClassVar[tuple[str, ...]] = ("cpu",)

    @property
    def sample_rate(self) -> int:
        return 16000

    def synthesize(self, text: str, voice: str, speed: float = 1.0) -> np.ndarray:
        seconds = max(0.3, len(text.split()) / 2.5 / speed)
        t = np.arange(int(seconds * self.sample_rate)) / self.sample_rate
        freq = 180 + zlib.crc32(voice.encode()) % 120  # a distinct pitch per voice
        env = 0.5 * (1 + np.sin(2 * np.pi * 3 * t))      # syllable-ish pulsing
        return (0.2 * env * np.sin(2 * np.pi * freq * t)).astype(np.float32)
