"""Text normalisation for speech, per-turn synthesis with caching, and final assembly.

Outputs: <name>.wav (always), <name>.mp3 with ID3 chapters (if ffmpeg), <name>.srt captions.
"""
from __future__ import annotations

import hashlib
import logging
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf

from .config import TTSConfig
from .script import Script
from .tts.base import TTSBackend

log = logging.getLogger(__name__)

EN_REPLACEMENTS = [
    (r"\bet al\.?", "and colleagues"), (r"\be\.g\.,?", "for example,"), (r"\bi\.e\.,?", "that is,"),
    (r"\bvs\.?", "versus"), (r"\bw\.r\.t\.", "with respect to"), (r"\bcf\.", "compare"),
    (r"≈|~(?=\s*\d)", "about "), (r"±", " plus or minus "), (r"×", " times "), (r"≥", " at least "),
    (r"≤", " at most "), (r"→", " to "), (r"(\d)\s*%", r"\1 percent"), (r"\bSOTA\b", "state of the art"),
]


def normalize_for_tts(text: str, language: str = "English") -> str:
    t = re.sub(r"[*_`#]+", "", text)                                  # markdown
    t = re.sub(r"\[(\d+([,\-–]\s*\d+)*)\]", "", t)                    # [12], [3-5]
    t = re.sub(r"\(([A-Z][\w\-]+( et al\.?)?,? \d{4}[a-z]?;?\s*)+\)", "", t)  # (Smith et al., 2020)
    t = re.sub(r"https?://\S+", "a link in the paper", t)
    if language.lower().startswith("en"):
        for pat, rep in EN_REPLACEMENTS:
            t = re.sub(pat, rep, t)
    t = re.sub(r"\s+([,.;:!?])", r"\1", t)
    return re.sub(r"\s{2,}", " ", t).strip()


def resample(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    if sr_in == sr_out or len(x) == 0:
        return x
    n = int(round(len(x) * sr_out / sr_in))
    return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)


def _level(x: np.ndarray, target_dbfs: float = -20.0, peak: float = 0.95) -> np.ndarray:
    if len(x) == 0:
        return x
    rms = float(np.sqrt(np.mean(x ** 2))) or 1e-9
    y = x * (10 ** (target_dbfs / 20) / rms)
    p = float(np.max(np.abs(y)))
    return y * (peak / p) if p > peak else y


def _fade(x: np.ndarray, sr: int, ms: float = 8) -> np.ndarray:
    n = min(len(x) // 2, int(sr * ms / 1000))
    if n > 0:
        ramp = np.linspace(0, 1, n, dtype=np.float32)
        x = x.copy()
        x[:n] *= ramp
        x[-n:] *= ramp[::-1]
    return x


def _ts(sec: float, srt: bool = True) -> str:
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{int(s):02d},{int((s % 1) * 1000):03d}"


@dataclass
class RenderResult:
    wav: Path
    mp3: Path | None
    srt: Path
    duration_s: float
    synth_s: float


def render(script: Script, backend: TTSBackend, cfg: TTSConfig, out_stem: Path,
           cache_dir: Path, progress=print, reporter=None) -> RenderResult:
    if reporter is not None:
        reporter.set_stage("audio", "Synthesizing podcast")
    sr = backend.sample_rate
    voices = {s["name"]: (s["voice"], float(s.get("speed", 1.0))) for s in script.speakers}
    for v, _ in voices.values():
        backend.validate_voice(v)
    tts_cache = cache_dir / "tts"
    tts_cache.mkdir(parents=True, exist_ok=True)

    pieces: list[np.ndarray] = []
    chapters: list[tuple[float, str]] = []
    subs: list[tuple[float, float, str]] = []
    cursor = 0.0
    total = sum(len(s.turns) for s in script.segments)
    done, t_synth = 0, 0.0

    def add_silence(sec: float):
        nonlocal cursor
        pieces.append(np.zeros(int(sec * sr), dtype=np.float32))
        cursor += sec

    prev_speaker = None
    for si, seg in enumerate(script.segments):
        if si > 0:
            add_silence(cfg.pause_segment_s)
        chapters.append((cursor, seg.title))
        for turn in seg.turns:
            voice, speed = voices[turn.speaker]
            text = normalize_for_tts(turn.text, script.language)
            key = hashlib.sha1(f"{backend.cache_key()}|{voice}|{speed}|{text}".encode()).hexdigest()
            f = tts_cache / f"{key}.wav"
            if f.exists():
                audio, file_sr = sf.read(f, dtype="float32")
                audio = resample(audio, file_sr, sr)
            else:
                t0 = time.time()
                audio = backend.synthesize(text, voice, speed)
                t_synth += time.time() - t0
                sf.write(f, audio, sr)
            audio = _fade(_level(audio), sr)
            if prev_speaker is not None and not (si > 0 and turn is seg.turns[0]):
                add_silence(cfg.pause_same_speaker_s if prev_speaker == turn.speaker
                            else cfg.pause_speaker_change_s)
            start = cursor
            pieces.append(audio)
            cursor += len(audio) / sr
            subs.append((start, cursor, f"{turn.speaker}: {turn.text}"))
            prev_speaker = turn.speaker
            done += 1
            if reporter is not None:
                reporter.set_message(f"Synthesizing turn {done}/{total}")
                reporter.advance(done / total if total else 1.0)
            if done % 10 == 0 or done == total:
                progress(f"  synthesized {done}/{total} turns ({cursor / 60:.1f} min of audio)")

    full = np.concatenate(pieces) if pieces else np.zeros(1, dtype=np.float32)
    wav = out_stem.with_suffix(".wav")
    sf.write(wav, full, sr, subtype="PCM_16")

    srt = out_stem.with_suffix(".srt")
    srt.write_text("\n".join(f"{i}\n{_ts(a)} --> {_ts(b)}\n{txt}\n" for i, (a, b, txt) in enumerate(subs, 1)))

    mp3 = None
    if cfg.output_format == "mp3":
        if shutil.which("ffmpeg"):
            meta = out_stem.with_suffix(".ffmeta")
            lines = [";FFMETADATA1", f"title={_esc(script.paper_title)}", "artist=paper2pod"]
            ends = [c[0] for c in chapters[1:]] + [cursor]
            for (start, title), end in zip(chapters, ends):
                lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={int(start * 1000)}",
                          f"END={int(end * 1000)}", f"title={_esc(title)}"]
            meta.write_text("\n".join(lines) + "\n")
            mp3 = out_stem.with_suffix(".mp3")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-i", str(meta),
                            "-map_metadata", "1", "-map_chapters", "1", "-codec:a", "libmp3lame",
                            "-q:a", "3", "-id3v2_version", "3", str(mp3)], check=True)
            meta.unlink(missing_ok=True)
        else:
            log.warning("ffmpeg not found; keeping WAV only")
    return RenderResult(wav, mp3, srt, cursor, t_synth)


def _esc(s: str) -> str:
    return re.sub(r"([=;#\\\n])", r"\\\1", s)
