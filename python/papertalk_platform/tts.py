"""Kokoro text-to-speech on the CPU with ONNX Runtime (FluidAudio on macOS).

Same Kokoro v1.0 voices as the macOS app (af_heart, am_michael, ...), so a
paper's cast means the same thing on both platforms. Output matches the
baked turns on macOS: 24 kHz mono 16-bit PCM WAV.
"""
import io
import os
import urllib.request

import numpy as np
import soundfile as sf

MODEL_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

_kokoro = None


def model_dir() -> str:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "papertalk", "kokoro")


def _paths():
    d = model_dir()
    return os.path.join(d, "kokoro-v1.0.onnx"), os.path.join(d, "voices-v1.0.bin")


def models_present() -> bool:
    return all(os.path.exists(p) for p in _paths())


def download_models(progress=None) -> None:
    """Fetch the model files if missing. `progress(fraction)` is called as they arrive."""
    os.makedirs(model_dir(), exist_ok=True)
    targets = [p for p in zip((MODEL_URL, VOICES_URL), _paths()) if not os.path.exists(p[1])]
    for index, (url, path) in enumerate(targets):
        partial = path + ".part"

        def hook(blocks, block_size, total, index=index):
            if progress and total > 0:
                progress((index + min(1.0, blocks * block_size / total)) / len(targets))

        urllib.request.urlretrieve(url, partial, reporthook=hook)
        os.replace(partial, path)


def prepare() -> None:
    """Load the model once (downloading it first if needed)."""
    global _kokoro
    if _kokoro is not None:
        return
    if not models_present():
        download_models()
    from kokoro_onnx import Kokoro

    _kokoro = Kokoro(*_paths())


def voices() -> list:
    prepare()
    return sorted(_kokoro.get_voices())


def synthesize(text: str, voice: str, speed: float = 1.0) -> bytes:
    """`text` spoken by `voice` as WAV bytes."""
    prepare()
    lang = "en-gb" if voice.startswith("b") else "en-us"
    samples, rate = _kokoro.create(text, voice=voice, speed=float(speed), lang=lang)
    out = io.BytesIO()
    sf.write(out, np.asarray(samples, dtype=np.float32), rate, format="WAV", subtype="PCM_16")
    return out.getvalue()
