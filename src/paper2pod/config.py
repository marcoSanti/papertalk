"""Configuration: YAML file + environment variables + CLI overrides.

Precedence (highest first): CLI flags > environment variables > YAML file > defaults.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field, fields, is_dataclass
from pathlib import Path
from typing import Any

import yaml


@dataclass
class LLMConfig:
    # OpenWebUI exposes its OpenAI-compatible API under <host>/api
    base_url: str = "http://localhost:3000/api"
    api_key: str = ""
    model: str = ""
    temperature: float = 0.7
    timeout_s: float = 900.0
    max_retries: int = 3
    # Context window handling ------------------------------------------------
    # If set, skips discovery entirely.
    context_window: int | None = None
    # Run the needle-in-a-haystack probe when metadata is missing/unreliable.
    # "auto" = only if metadata gave nothing; "always"; "never".
    probe_context: str = "auto"
    probe_max_tokens: int = 131072
    fallback_context_window: int = 8192
    # Tokens reserved for each completion; capped to a fraction of the window.
    max_output_tokens: int = 4096
    # Extra JSON merged into every chat request, e.g. {"options": {"num_ctx": 32768}}
    # for Ollama-backed models whose runtime context is smaller than the model max.
    extra_body: dict[str, Any] = field(default_factory=dict)
    # Initial chars-per-token guess; recalibrated from `usage` in responses.
    chars_per_token: float = 3.2


@dataclass
class Speaker:
    name: str
    role: str
    persona: str
    voice: str
    speed: float = 1.0


@dataclass
class ScriptConfig:
    # "host_expert" or "peers" (or any key under `styles` in your YAML)
    style: str = "host_expert"
    language: str = "English"
    target_minutes: float = 25.0
    words_per_minute: int = 150
    include_references: bool = False
    # Rolling memory passed to each segment call
    recent_turns_verbatim: int = 8
    # Role of the speaker cast as the first author (renamed + revoiced when authors are found).
    author_speaker: str = "expert"
    # auto (= infer from the name) | male | female. "auto" picks the voice by name gender.
    author_gender: str = "auto"
    speakers: dict[str, list[Speaker]] = field(default_factory=dict)


@dataclass
class TTSConfig:
    backend: str = "kokoro"          # registry name or "package.module:ClassName"
    device: str = "auto"             # auto | cuda | mps | cpu
    options: dict[str, Any] = field(default_factory=dict)
    pause_same_speaker_s: float = 0.25
    pause_speaker_change_s: float = 0.45
    pause_segment_s: float = 1.2
    output_format: str = "mp3"       # mp3 | wav


@dataclass
class Config:
    llm: LLMConfig = field(default_factory=LLMConfig)
    script: ScriptConfig = field(default_factory=ScriptConfig)
    tts: TTSConfig = field(default_factory=TTSConfig)
    cache_dir: str = "~/.cache/paper2pod"


DEFAULT_SPEAKERS: dict[str, list[Speaker]] = {
    "host_expert": [
        Speaker(
            name="Alex",
            role="host",
            persona=(
                "A sharp science-podcast host with a technical background but not a specialist "
                "in this field. Asks the questions a smart listener would ask, requests concrete "
                "examples, pushes for intuition behind equations, and summarises at transitions."
            ),
            voice="af_heart",
        ),
        Speaker(
            name="Sam",
            role="expert",
            persona=(
                "A domain expert who has read the paper closely. Explains methods, math, "
                "experimental setup and results precisely, quotes the actual numbers, and is "
                "candid about limitations and open questions."
            ),
            voice="am_michael",
        ),
    ],
    "peers": [
        Speaker(
            name="Maya",
            role="researcher",
            persona=(
                "A researcher in the paper's field, presenting it at a journal club. Walks through "
                "the contribution and method in detail and defends the authors' choices where justified."
            ),
            voice="af_bella",
        ),
        Speaker(
            name="Leo",
            role="researcher",
            persona=(
                "A researcher from an adjacent field acting as a constructive critic. Probes "
                "assumptions, baselines, statistical validity, reproducibility and alternative "
                "explanations, and relates the work to the wider literature."
            ),
            voice="bm_george",
        ),
    ],
}


def _merge(dc: Any, data: dict[str, Any]) -> Any:
    """Recursively merge a plain dict into a dataclass instance."""
    for f in fields(dc):
        if f.name not in data:
            continue
        cur = getattr(dc, f.name)
        val = data[f.name]
        if is_dataclass(cur) and isinstance(val, dict):
            _merge(cur, val)
        elif f.name == "speakers" and isinstance(val, dict):
            setattr(dc, f.name, {k: [Speaker(**s) for s in v] for k, v in val.items()})
        else:
            setattr(dc, f.name, val)
    return dc


def load_config(path: str | os.PathLike | None = None) -> Config:
    cfg = Config()
    cfg.script.speakers = {k: list(v) for k, v in DEFAULT_SPEAKERS.items()}
    if path:
        data = yaml.safe_load(Path(path).read_text()) or {}
        user_speakers = (data.get("script") or {}).pop("speakers", None)
        _merge(cfg, data)
        if user_speakers:
            for k, v in user_speakers.items():
                cfg.script.speakers[k] = [Speaker(**s) for s in v]

    env = os.environ
    cfg.llm.base_url = env.get("OPENWEBUI_BASE_URL", cfg.llm.base_url)
    cfg.llm.api_key = env.get("OPENWEBUI_API_KEY", cfg.llm.api_key)
    cfg.llm.model = env.get("PAPER2POD_MODEL", cfg.llm.model)
    if env.get("PAPER2POD_CONTEXT_WINDOW"):
        cfg.llm.context_window = int(env["PAPER2POD_CONTEXT_WINDOW"])
    cfg.tts.device = env.get("PAPER2POD_DEVICE", cfg.tts.device)
    return cfg


def speakers_for(cfg: Config) -> list[Speaker]:
    style = cfg.script.style
    if style not in cfg.script.speakers:
        raise ValueError(
            f"Unknown style '{style}'. Available: {', '.join(cfg.script.speakers)}"
        )
    sp = cfg.script.speakers[style]
    if len(sp) != 2:
        raise ValueError(f"Style '{style}' must define exactly 2 speakers, got {len(sp)}")
    return sp
