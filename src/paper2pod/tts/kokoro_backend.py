"""Kokoro-82M backend (https://huggingface.co/hexgrad/Kokoro-82M).

Small (82M params), 24 kHz, runs in real time on CPU and much faster on CUDA/MPS.
One KModel is shared across per-language KPipelines; the language is taken from the
voice prefix (af_* -> 'a' American English, bm_* -> 'b' British, if_* -> 'i' Italian...).
Non-English languages need espeak-ng installed on the system.
"""
from __future__ import annotations

import logging
from typing import ClassVar

import numpy as np

from .base import TTSBackend

log = logging.getLogger(__name__)

KOKORO_VOICES = (
    "af_heart af_alloy af_aoede af_bella af_jessica af_kore af_nicole af_nova af_river af_sarah af_sky "
    "am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck am_santa "
    "bf_alice bf_emma bf_isabella bf_lily bm_daniel bm_fable bm_george bm_lewis "
    "ef_dora em_alex em_santa ff_siwis hf_alpha hf_beta hm_omega hm_psi if_sara im_nicola "
    "jf_alpha jf_gongitsune jf_nezumi jf_tebukuro jm_kumo pf_dora pm_alex pm_santa "
    "zf_xiaobei zf_xiaoni zf_xiaoxiao zf_xiaoyi zm_yunjian zm_yunxi zm_yunxia zm_yunyang"
).split()


class KokoroBackend(TTSBackend):
    name = "kokoro"
    supported_devices: ClassVar[tuple[str, ...]] = ("cuda", "mps", "cpu")

    def __init__(self, device: str = "cpu", repo_id: str = "hexgrad/Kokoro-82M", **options):
        super().__init__(device, repo_id=repo_id, **options)
        try:
            from kokoro import KModel  # noqa: PLC0415
        except ImportError as e:
            raise ImportError("Kokoro backend needs: pip install 'paper2pod' "
                              "(and espeak-ng for non-English voices)") from e
        try:
            model = KModel(repo_id=repo_id)          # kokoro >= 0.9
        except TypeError:
            model = KModel()                          # older releases
        self.model = model.to(device).eval()
        self.repo_id = repo_id
        self._pipelines: dict[str, object] = {}
        log.info("Kokoro loaded on %s", device)

    @property
    def sample_rate(self) -> int:
        return 24000

    def list_voices(self) -> list[str]:
        return list(KOKORO_VOICES)

    def validate_voice(self, voice: str) -> None:
        # Allows custom .pt voice files and blends like "af_bella,af_heart".
        for v in voice.split(","):
            if not v.endswith(".pt") and v not in KOKORO_VOICES:
                raise ValueError(f"[kokoro] unknown voice '{v}'")
        langs = {v.split("/")[-1][0] for v in voice.split(",")}
        if len(langs) > 1:
            raise ValueError(f"[kokoro] blended voices must share a language: {voice}")

    def _pipeline(self, lang: str):
        if lang not in self._pipelines:
            from kokoro import KPipeline  # noqa: PLC0415
            try:
                self._pipelines[lang] = KPipeline(lang_code=lang, repo_id=self.repo_id, model=self.model)
            except TypeError:
                self._pipelines[lang] = KPipeline(lang_code=lang, model=self.model)
        return self._pipelines[lang]

    def synthesize(self, text: str, voice: str, speed: float = 1.0) -> np.ndarray:
        lang = voice.split(",")[0].split("/")[-1][0]
        pipe = self._pipeline(lang)
        chunks = []
        for _gs, _ps, audio in pipe(text, voice=voice, speed=speed, split_pattern=r"\n+"):
            if audio is not None:
                chunks.append(audio.detach().cpu().numpy() if hasattr(audio, "detach") else np.asarray(audio))
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(chunks).astype(np.float32)

    def cache_key(self) -> str:
        return f"kokoro:{self.repo_id}"

    def close(self) -> None:
        self._pipelines.clear()
        try:
            import torch  # noqa: PLC0415
            if self.device == "cuda":
                torch.cuda.empty_cache()
        except ImportError:
            pass
