"""Client for an OpenAI-compatible endpoint (OpenWebUI first), with context-window discovery.

Why discovery is non-trivial with OpenWebUI:
  * `/api/models` lists models but rarely states a context length.
  * Workspace models may carry `info.params.num_ctx`.
  * Ollama-backed models report an *architectural* max (`<arch>.context_length`)
    but run with a much smaller `num_ctx` unless configured; Ollama silently
    truncates the *start* of an over-long prompt instead of erroring.
So we combine: explicit config > model metadata > Ollama /api/show > an empirical
needle-in-a-haystack probe that detects silent truncation. Results are cached.
"""
from __future__ import annotations

import hashlib
import json
import logging
import random
import re
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import httpx
from openai import BadRequestError, OpenAI

from .config import LLMConfig

log = logging.getLogger(__name__)

THINK_RE = re.compile(r"<think>.*?</think>", re.S | re.I)
CTX_KEYS = ("context_length", "context_window", "max_context_length", "max_model_len",
            "n_ctx", "num_ctx", "max_position_embeddings")


class ContextTruncatedError(RuntimeError):
    """The server silently truncated a prompt: the context window was overestimated."""


@dataclass
class ContextInfo:
    window: int
    source: str
    reliable: bool
    notes: list[str] = field(default_factory=list)
    chars_per_token: float | None = None


@dataclass
class Budget:
    window: int
    max_output: int
    max_input: int


@dataclass
class ChatResult:
    text: str
    finish_reason: str | None
    prompt_tokens: int | None
    completion_tokens: int | None


class TokenEstimator:
    """chars/token estimate, recalibrated from server-reported usage."""

    def __init__(self, chars_per_token: float):
        self.cpt = chars_per_token

    def count(self, text: str) -> int:
        return int(len(text) / self.cpt) + 1

    def chars_for(self, tokens: int) -> int:
        return int(tokens * self.cpt)

    def observe(self, n_chars: int, prompt_tokens: int | None) -> None:
        if not prompt_tokens or n_chars < 2000:
            return
        observed = n_chars / prompt_tokens
        if 1.5 < observed < 8:
            # Move fast towards "more tokens than thought" (dangerous), slowly the other way.
            w = 0.5 if observed < self.cpt else 0.15
            self.cpt = (1 - w) * self.cpt + w * observed


def _find_ctx(obj: Any, depth: int = 0) -> int | None:
    """Search a model-metadata dict for anything that looks like a context length."""
    if depth > 4 or not isinstance(obj, dict):
        return None
    for k, v in obj.items():
        if (k in CTX_KEYS or k.endswith(".context_length")) and isinstance(v, (int, float)) and v > 0:
            return int(v)
    for v in obj.values():
        if isinstance(v, dict):
            r = _find_ctx(v, depth + 1)
            if r:
                return r
    return None


class LLMClient:
    def __init__(self, cfg: LLMConfig, cache_dir: str | Path = "~/.cache/paper2pod"):
        if not cfg.model:
            raise ValueError("No model configured (llm.model / PAPER2POD_MODEL / --model)")
        self.cfg = cfg
        self.base_url = cfg.base_url.rstrip("/")
        headers = {"Authorization": f"Bearer {cfg.api_key}"} if cfg.api_key else {}
        self.http = httpx.Client(timeout=60, headers=headers)
        self.client = OpenAI(base_url=self.base_url, api_key=cfg.api_key or "none",
                             timeout=cfg.timeout_s, max_retries=cfg.max_retries)
        self.tokens = TokenEstimator(cfg.chars_per_token)
        self.cache_dir = Path(cache_dir).expanduser()
        self._ctx: ContextInfo | None = None
        self.usage = {"prompt": 0, "completion": 0, "calls": 0}

    # ------------------------------------------------------------------ models
    @property
    def server_root(self) -> str:
        """OpenWebUI root (strip trailing /api or /v1)."""
        return re.sub(r"/(api|v1)$", "", self.base_url)

    def list_models(self) -> list[dict]:
        r = self.http.get(f"{self.base_url}/models")
        r.raise_for_status()
        data = r.json()
        return data.get("data", data) if isinstance(data, dict) else data

    def model_entry(self) -> dict | None:
        for m in self.list_models():
            if m.get("id") == self.cfg.model or m.get("name") == self.cfg.model:
                return m
        return None

    def _ollama_show(self, name: str) -> dict | None:
        for url in (f"{self.server_root}/ollama/api/show", f"{self.server_root}/api/show"):
            try:
                r = self.http.post(url, json={"model": name, "name": name})
                if r.status_code == 200 and isinstance(r.json(), dict):
                    return r.json()
            except (httpx.HTTPError, ValueError):
                continue
        return None

    # --------------------------------------------------------------- discovery
    def _cache_path(self) -> Path:
        key = json.dumps([self.base_url, self.cfg.model, self.cfg.extra_body], sort_keys=True)
        return self.cache_dir / "context" / (hashlib.sha1(key.encode()).hexdigest()[:16] + ".json")

    def discover_context(self, refresh: bool = False) -> ContextInfo:
        if self._ctx and not refresh:
            return self._ctx
        if self.cfg.context_window:
            self._ctx = ContextInfo(self.cfg.context_window, "config", True)
            return self._ctx

        cache = self._cache_path()
        if cache.exists() and not refresh:
            info = ContextInfo(**json.loads(cache.read_text()))
            if info.chars_per_token:
                self.tokens.cpt = info.chars_per_token
            self._ctx = info
            log.info("Context window %d (cached, from %s)", info.window, info.source)
            return info

        info = self._discover_from_metadata()
        need_probe = self.cfg.probe_context == "always" or (
            self.cfg.probe_context == "auto" and (info is None or not info.reliable))
        if need_probe:
            upper = info.window if info else self.cfg.probe_max_tokens
            probed = self.probe_context(min(upper, self.cfg.probe_max_tokens))
            if probed:
                notes = (info.notes if info else []) + [f"probe passed at {probed} tokens"]
                info = ContextInfo(probed, "probe", True, notes, self.tokens.cpt)
        if info is None:
            info = ContextInfo(self.cfg.fallback_context_window, "fallback", False,
                               ["no metadata and probe disabled/failed"])
            log.warning("Could not determine context window; using fallback %d", info.window)

        info.chars_per_token = self.tokens.cpt
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(asdict(info), indent=2))
        self._ctx = info
        return info

    def _discover_from_metadata(self) -> ContextInfo | None:
        notes: list[str] = []
        try:
            entry = self.model_entry()
        except httpx.HTTPError as e:
            notes.append(f"/models failed: {e}")
            entry = None
        if entry is None:
            log.warning("Model %s not found in /models listing", self.cfg.model)
            return None

        # 1) explicit num_ctx on an OpenWebUI workspace model or in our extra_body
        # (num_ctx we *send* via extra_body is only trusted after the probe confirms that
        #  OpenWebUI forwarded it; num_ctx stored on the OpenWebUI model is applied server-side.)
        explicit, explicit_trusted = None, False
        for src, trusted in ((self.cfg.extra_body.get("options", {}), False),
                             (self.cfg.extra_body, False),
                             ((entry.get("info") or {}).get("params") or {}, True),
                             (entry.get("params") or {}, True)):
            if isinstance(src, dict) and src.get("num_ctx"):
                explicit, explicit_trusted = int(src["num_ctx"]), trusted
                break

        is_ollama = "ollama" in entry or entry.get("owned_by") == "ollama"
        if is_ollama:
            base = (entry.get("info") or {}).get("base_model_id") or entry.get("id")
            show = self._ollama_show(base) or {}
            arch_max = _find_ctx(show.get("model_info") or {})
            m = re.search(r"num_ctx\s+(\d+)", show.get("parameters") or "")
            modelfile_ctx = int(m.group(1)) if m else None
            notes.append(f"ollama arch_max={arch_max} modelfile num_ctx={modelfile_ctx} "
                         f"requested num_ctx={explicit}")
            runtime = explicit or modelfile_ctx
            if runtime:
                win = min(runtime, arch_max) if arch_max else runtime
                reliable = explicit_trusted if explicit else True
                return ContextInfo(win, "ollama num_ctx", reliable, notes)
            if arch_max:
                # Model *could* do arch_max but Ollama's runtime default is likely smaller.
                notes.append("num_ctx not set: Ollama may silently truncate; probing advised")
                return ContextInfo(arch_max, "ollama model_info", False, notes)
            return None

        meta = explicit or _find_ctx(entry)
        if meta:
            notes.append(f"from /models metadata: {meta}")
            return ContextInfo(meta, "models metadata", explicit_trusted or not explicit, notes)
        return None

    def probe_context(self, upper: int) -> int | None:
        """Needle-in-a-haystack: largest prompt size at which the start is still visible."""
        sizes = [s for s in (2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144) if s <= upper]
        if upper not in sizes and upper > 2048:
            sizes.append(upper)
        passed, failed = None, None
        for size in sizes:
            ok = self._probe_once(size)
            log.info("context probe %6d tokens: %s", size, "ok" if ok else "FAIL")
            if not ok:
                failed = size
                break
            passed = size
        # Two bisection steps narrow the gap between doublings to ~25%.
        if passed and failed:
            for _ in range(2):
                mid = (passed + failed) // 2
                ok = self._probe_once(mid)
                log.info("context probe %6d tokens: %s", mid, "ok" if ok else "FAIL")
                passed, failed = (mid, failed) if ok else (passed, mid)
        return passed

    def _probe_once(self, size: int) -> bool:
        rng = random.Random(size)
        code = f"{rng.choice(['PLUM','ORCA','KITE','FERN'])}-{rng.randint(1000, 9999)}"
        head = f"The secret code is {code}. Remember it.\n"
        tail = "\nWhat is the secret code stated at the very beginning? Reply with the code only."
        target_tokens = int(size * 0.97) - 64  # nearly full: "pass at N" must mean N fits
        lines, n_chars = [], 0
        budget_chars = self.tokens.chars_for(target_tokens)
        i = 0
        while n_chars < budget_chars:
            line = (f"Record {i:05d}: sample {rng.randint(1, 999)} measured "
                    f"{rng.random() * 100:.2f} units under condition {rng.choice('ABCDEFG')}.\n")
            lines.append(line)
            n_chars += len(line)
            i += 1
        prompt = head + "".join(lines) + tail
        try:
            res = self.chat([{"role": "user", "content": prompt}], max_tokens=24,
                            temperature=0.0, _probe=True)
        except BadRequestError:
            return False  # server refused: exceeds context
        except Exception as e:  # noqa: BLE001
            log.warning("probe error at %d: %s", size, e)
            return False
        if res.prompt_tokens and res.prompt_tokens < 0.8 * self.tokens.count(prompt):
            return False  # server-side truncation reported via usage
        return code.lower() in res.text.lower()

    # ------------------------------------------------------------------ budget
    def budget(self) -> Budget:
        win = self.discover_context().window
        max_out = max(512, min(self.cfg.max_output_tokens, win // 3))
        margin = max(256, int(0.06 * win))
        return Budget(win, max_out, win - max_out - margin)

    # -------------------------------------------------------------------- chat
    def chat(self, messages: list[dict], max_tokens: int | None = None,
             temperature: float | None = None, _probe: bool = False) -> ChatResult:
        max_tokens = max_tokens or self.budget().max_output
        t0 = time.time()
        resp = self.client.chat.completions.create(
            model=self.cfg.model,
            messages=messages,
            temperature=self.cfg.temperature if temperature is None else temperature,
            max_tokens=max_tokens,
            stream=False,
            extra_body=self.cfg.extra_body or None,
        )
        choice = resp.choices[0]
        text = THINK_RE.sub("", choice.message.content or "").strip()
        pt = getattr(resp.usage, "prompt_tokens", None) if resp.usage else None
        ct = getattr(resp.usage, "completion_tokens", None) if resp.usage else None
        n_chars = sum(len(m["content"]) for m in messages)
        if not _probe and pt and n_chars > 6000 and pt < 0.6 * n_chars / self.tokens.cpt:
            # The server counted far fewer tokens than we sent: it silently dropped part of the
            # prompt (typical of Ollama with a small num_ctx). Continuing would yield garbage.
            raise ContextTruncatedError(
                f"Server reported {pt} prompt tokens for ~{int(n_chars / self.tokens.cpt)} sent: the "
                f"prompt was truncated, so the real context window is smaller than {self.budget().window}. "
                "Re-run with --probe (or `paper2pod models --model X --probe`) or --context-window N.")
        self.tokens.observe(n_chars, pt)
        self.usage["calls"] += 1
        self.usage["prompt"] += pt or 0
        self.usage["completion"] += ct or 0
        if not _probe:
            log.debug("chat %.1fs prompt=%s completion=%s finish=%s",
                      time.time() - t0, pt, ct, choice.finish_reason)
        return ChatResult(text, choice.finish_reason, pt, ct)
