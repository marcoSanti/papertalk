"""Any *local* TTS server exposing OpenAI's POST /v1/audio/speech.

Covers Kokoro-FastAPI, openedai-speech (XTTS/Piper), AllTalk, LocalAI, Orpheus-FastAPI, etc.,
so heavier models can run in their own process/container (or on another GPU box)
without changing this project's dependencies.

    tts:
      backend: openai_http
      options: {base_url: "http://localhost:8880/v1", model: "kokoro", api_key: ""}
"""
from __future__ import annotations

import io
from typing import ClassVar

import httpx
import numpy as np
import soundfile as sf

from .base import TTSBackend


class OpenAIHTTPBackend(TTSBackend):
    name = "openai_http"
    # Device is the server's business; we just do HTTP.
    supported_devices: ClassVar[tuple[str, ...]] = ("cpu", "cuda", "mps")

    def __init__(self, device: str = "cpu", base_url: str = "http://localhost:8880/v1",
                 model: str = "kokoro", api_key: str = "", sample_rate: int = 24000,
                 timeout_s: float = 300, voices: list[str] | None = None, **options):
        super().__init__(device, base_url=base_url, model=model, **options)
        self.url = base_url.rstrip("/") + "/audio/speech"
        self.model = model
        self._sr = sample_rate
        self._voices = voices or []
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self.http = httpx.Client(timeout=timeout_s, headers=headers)
        self.extra = options

    @property
    def sample_rate(self) -> int:
        return self._sr

    def list_voices(self) -> list[str]:
        return self._voices

    def synthesize(self, text: str, voice: str, speed: float = 1.0) -> np.ndarray:
        r = self.http.post(self.url, json={"model": self.model, "input": text, "voice": voice,
                                           "speed": speed, "response_format": "wav", **self.extra})
        r.raise_for_status()
        audio, sr = sf.read(io.BytesIO(r.content), dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        if sr != self._sr:
            from ..audio import resample  # noqa: PLC0415
            audio = resample(audio, sr, self._sr)
        return audio

    def cache_key(self) -> str:
        return f"openai_http:{self.url}:{self.model}"

    def close(self) -> None:
        self.http.close()
