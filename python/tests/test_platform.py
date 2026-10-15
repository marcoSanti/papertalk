"""Offline tests for the Linux platform services. The Kokoro test needs the
model files (~340 MB) and runs only with PAPERTALK_TTS_TESTS=1."""
import io
import os

import numpy as np
import pytest
import soundfile as sf

from conftest import make_pdf
from papertalk_platform import audio, keychain, pdf, tts


def wav(seconds: float, rate: int = 24_000) -> bytes:
    out = io.BytesIO()
    sf.write(out, np.zeros(int(seconds * rate), np.float32), rate, format="WAV", subtype="PCM_16")
    return out.getvalue()


def test_pdf_text():
    assert "Hello Papertalk" in pdf.text(make_pdf())


def test_pdf_cover_is_png_of_requested_width():
    png = pdf.cover_png(make_pdf(), 200)
    assert png.startswith(b"\x89PNG")
    from PIL import Image

    assert Image.open(io.BytesIO(png)).width == 200


def test_unreadable_pdf_gives_empty_results():
    assert pdf.text(b"not a pdf") == ""
    assert pdf.cover_png(b"not a pdf") == b""


def test_player_clock_seek_and_end():
    p = audio.Player(wav(2.0))
    assert p.duration == pytest.approx(2.0)
    p.seek(1.5)
    assert p.current_time == pytest.approx(1.5)
    chunk = p.read(24_000)  # 1 s requested, 0.5 s left: zero-padded
    assert chunk.shape == (24_000, 1)
    assert p.finished
    p.seek(99)
    assert p.current_time == pytest.approx(2.0)
    p.seek(0)
    assert not p.finished


def test_keychain_roundtrip(monkeypatch):
    store = {}
    monkeypatch.setattr(keychain.keyring, "get_password", lambda s, a: store.get((s, a)))
    monkeypatch.setattr(keychain.keyring, "set_password", lambda s, a, v: store.__setitem__((s, a), v))
    monkeypatch.setattr(keychain.keyring, "delete_password", lambda s, a: store.pop((s, a)))
    assert keychain.read("llm") == ""
    assert keychain.write("llm", "sk-test")
    assert keychain.read("llm") == "sk-test"
    keychain.delete("llm")
    assert keychain.read("llm") == ""


@pytest.mark.skipif(os.environ.get("PAPERTALK_TTS_TESTS") != "1", reason="needs Kokoro model files")
def test_kokoro_speaks_the_macos_voices():
    assert {"af_heart", "am_michael", "bf_emma", "bm_george"} <= set(tts.voices())
    data, rate = sf.read(io.BytesIO(tts.synthesize("Hello from Papertalk.", "af_heart")))
    assert rate == 24_000 and data.ndim == 1 and len(data) > rate // 2
