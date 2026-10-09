# paper2pod — design

Turn a scientific paper (PDF) into a detailed two-person spoken discussion.
A **remote** OpenAI-compatible model (OpenWebUI, accessed with an API key) writes the
script; a **local** text-to-speech model voices it.

```
 paper.pdf
    │  1. extract (PyMuPDF, local)
    ▼
 paper.json ── sections, abstract, captions
    │  2. discover context window of the remote model ──► budget per call
    │  3. knowledge: full text if it fits, else notes per chunk (map) + reduce
    ▼
 notes.json (only if needed)
    │  4. outline: 1 call → JSON segments {title, goal, sections[], key_points[], weight}
    │  5. dialogue: 1+ call per segment (source text + plan + rolling memory)
    ▼
 outline.json (checkpoint) → script.json / script.md   ◄── editable by hand
    │  6. TTS plugin (Kokoro by default) per turn, cached
    │  7. assemble: level, pauses, chapters, captions
    ▼
 podcast.mp3 (with chapters) + podcast.wav + podcast.srt
```

Every arrow writes a file in `out/<paper>/`, so any stage can be re-run, resumed after a
crash, or inspected/edited before the next stage (e.g. fix a line in `script.json`, then
`paper2pod synth`).

---

## 1. Modules

| Module | Responsibility |
|---|---|
| `pdf_extract.py` | PDF → `Paper(title, abstract, sections[], captions[])` |
| `llm.py` | OpenAI-compatible client, context-window discovery, budget, truncation guard |
| `prompts.py` | All prompt text (styles, spoken-language rules, notes/outline/segment prompts) |
| `script.py` | Knowledge building, outline, per-segment dialogue, parsing, checkpoints |
| `tts/` | Plugin contract, registry, device selection, Kokoro / HTTP / null backends |
| `audio.py` | Text normalisation for speech, per-turn cache, assembly, MP3 chapters, SRT |
| `cli.py` | `run`, `script`, `synth`, `extract`, `models`, `backends` |

## 2. PDF extraction

PyMuPDF reads every line with its font size and weight. Then:

1. **Running headers/footers** — lines (digits normalised) repeated on ≥40 % of pages are dropped, as are bare page numbers.
2. **Body size** — most common font size, weighted by characters.
3. **Headings** — short lines that match a known section name (Introduction, Methods, …) or a numbered pattern (`3.2 Training`) *and* are bold, larger than body text, or uppercase.
4. **References** are flagged and excluded from the discussion by default (`include_references`).
5. **Captions** (`Figure 3:`, `Table 2.`) are collected separately and re-attached to whichever segment mentions them.
6. **Fallback** — if fewer than two headings are found, each page becomes a pseudo-section, so the rest of the pipeline still works.

Known limits: equations come out as whatever Unicode the PDF contains (the LLM is told to
put them into words), tables lose their layout, and scanned PDFs need OCR first (`ocrmypdf`).
`paper2pod extract paper.pdf` shows what was detected. Extraction is one function, so it can be
swapped for GROBID, `marker` or Nougat when better math/table handling matters.

## 3. Remote model and the context window

This is the subtle part. With OpenWebUI the context window is usually **not** stated:

* `GET /api/models` lists models. OpenAI-style providers sometimes include `context_length`; vLLM uses `max_model_len`.
* OpenWebUI workspace models may carry `info.params.num_ctx`.
* **Ollama-backed models** expose an *architectural* maximum (`llama.context_length = 131072`) through `/ollama/api/show`, but they **run** with a much smaller `num_ctx` unless it is configured. Ollama then **silently drops the start of the prompt** instead of returning an error. A naive client would send a 40k-token paper into an 8k window and get a confident discussion of the last few pages.

### Discovery chain (`LLMClient.discover_context`)

1. `llm.context_window` in config / `--context-window` → used as is.
2. Model metadata from `/api/models` (any of `context_length`, `context_window`, `max_model_len`, `num_ctx`, …).
3. For Ollama models: `/ollama/api/show` → Modelfile `num_ctx` (trusted) or architectural max (**not trusted**).
4. **Needle-in-a-haystack probe** (runs when 1–3 give nothing or nothing trustworthy, or always with `--probe`): a code word goes at the very start of a filler prompt sized to N tokens, and the model is asked to repeat it. N doubles (2k, 4k, 8k, …) up to the metadata value, then two bisection steps narrow the gap. Silent truncation removes the start, so the code word is lost and the test fails. A 400 error and a server-reported `prompt_tokens` far below the amount sent also count as failures.
5. Fallback of `8192` with a warning.

The result is cached per (server, model, `extra_body`) in `~/.cache/paper2pod/context/`.
`paper2pod models --model X --probe` shows the result and the evidence.

To give an Ollama model a bigger window, either set `num_ctx` on the model in OpenWebUI's
workspace (applied server-side, and trusted) or send it per request with
`llm.extra_body: {options: {num_ctx: 32768}}`. Because forwarding of that field depends on the
OpenWebUI version, it counts as *unverified* until the probe confirms it.

### Budget per call

```
max_output = min(llm.max_output_tokens, window / 3)
margin     = max(256, 6 % of window)
max_input  = window − max_output − margin
room       = max_input − tokens(system prompt) − tokens(instructions)   # measured per prompt
```

Token counts are estimated as `chars / chars_per_token`, starting from a conservative 3.2. The
estimate is recalibrated from the server's `usage.prompt_tokens` on every call. It adjusts
quickly when there turn out to be *more* tokens than expected (the dangerous direction) and slowly
the other way. This avoids needing the remote model's tokenizer.

### Truncation guard

On every normal call, if the server reports fewer than 60 % of the tokens sent, the run stops
with `ContextTruncatedError` and tells you to probe. This catches metadata that is wrong,
which would otherwise produce a confident hallucination.

## 4. Script generation

### Knowledge
* **Direct mode** — when the whole paper (title + abstract + sections + captions) fits in the outline `room`, the outline sees the original text.
* **Digest mode** — otherwise sections are packed into chunks that fit `room` (oversized sections are split on paragraph, then sentence, boundaries). Each chunk becomes dense **notes** that keep every number, equation (in words and symbols), hyperparameter, dataset, baseline and limitation, tagged `[SECTION i]` so they map back to sections. If the joined notes still don't fit, they are **reduced** recursively (at most 4 rounds, then truncated with a warning). Notes are checkpointed in `notes.json`.

### Outline (one call, JSON)
The model gets a numbered **section index** and returns segments that each reference section
*numbers* (robust to heading-name drift) and carry paper-specific `key_points` and a `weight`.
The code then:
* repairs common JSON mistakes (code fences, trailing commas, smart quotes) and retries up to 3 times;
* guarantees every non-reference section is used by at least one segment;
* splits `target_minutes × words_per_minute` across segments by weight.

The segment count scales with the target length (about one segment per 2–5 minutes).

### Dialogue (per segment)
Each call contains:
* the **system prompt**: both personas, the style guide, the "write for the ear" rules, and the language;
* the **whole plan** with the current segment marked, so the model knows what comes later and doesn't pre-empt it;
* the segment's **goal and key points**, which must all be covered;
* **memory**: key points already covered by earlier segments, plus the last *N* turns verbatim for continuity (N shrinks automatically when the window is tight);
* **source material**: the original text of the referenced sections plus relevant captions if they fit, else their notes, else truncated notes;
* **position rules**: the opening introduces the paper, middle segments have no greetings, the closing gives a verdict and sign-off.

If a segment's word target is more than one completion can hold, it is written in **parts**,
each continuing from the previous part's last lines.

Output is plain `NAME: text` lines rather than JSON, because local models produce this far more
reliably. The parser tolerates `**Name:**`, `Name (laughing):` and wrapped lines, and merges
consecutive turns by the same speaker. If parsing fails, the prompt is resent with a format
reminder. `<think>…</think>` blocks from reasoning models are removed.

### Styles
| `style` | Speakers | Dynamic |
|---|---|---|
| `host_expert` | Alex (host), Sam (expert) | The host asks, paraphrases and pushes for intuition; the expert carries the technical content with exact figures |
| `peers` | Maya, Leo (researchers) | Journal club: one presents and defends, the other probes assumptions, baselines, statistics and reproducibility; they end on a balanced verdict |

Styles are data. Any YAML key under `script.speakers` with two speakers becomes a new style,
for example an Italian pair with `if_sara` / `im_nicola` voices and `language: Italian`.

### Faithfulness
The prompts forbid inventing results, require speakers to say when the paper doesn't specify
something, and require numbers to be quoted from the source. Because each segment gets the
original section text whenever it fits, details survive better than with a single
summarise-then-talk pass.

## 5. Audio

* **Normalisation for speech** (`normalize_for_tts`): strip markdown, citation markers (`[12]`, `(Smith et al., 2020)`) and URLs. For English, expand `e.g.`, `i.e.`, `et al.`, `%`, `±`, `≈`, `≥`, ….
* **Per-turn synthesis, cached** by `sha1(backend.cache_key, voice, speed, text)`. Re-running after editing one line re-synthesises only that line.
* **Levelling**: each clip goes to −20 dBFS RMS with a peak limit, so the two voices sound equally loud, and gets 8 ms fades so there are no clicks.
* **Pauses**: 0.45 s when the speaker changes, 0.25 s for the same speaker, 1.2 s between segments (all configurable).
* **Outputs**: 16-bit WAV, MP3 with **ID3 chapters** (one per segment, via ffmpeg) so podcast players can jump between topics, and an **SRT** transcript with timestamps.

## 6. TTS plugin system

### Contract (`tts/base.py`)
```python
class TTSBackend(ABC):
    name: ClassVar[str]
    supported_devices: ClassVar[tuple[str, ...]]      # e.g. ("cuda", "mps", "cpu")
    def __init__(self, device: str, **options): ...
    @property
    def sample_rate(self) -> int: ...
    def synthesize(self, text: str, voice: str, speed: float = 1.0) -> np.ndarray: ...  # mono float32
    def list_voices(self) -> list[str]: ...            # optional
    def validate_voice(self, voice: str) -> None: ...  # fail before hours of work
    def cache_key(self) -> str: ...                    # model id/options that change the audio
    def close(self) -> None: ...
```
A backend only turns text into samples. Normalisation, pauses, levelling, caching, resampling
and encoding are shared, so a new engine takes roughly 40 lines.

### Three ways to register a backend
1. **Built-in name** — `kokoro`, `openai_http`, `null`.
2. **Entry point** in any installed package:
   ```toml
   [project.entry-points."paper2pod.tts"]
   xtts = "paper2pod_xtts:XTTSBackend"
   ```
3. **Import path** in config: `tts.backend: "my_backends:PiperBackend"`.

`tts.options` is passed to the backend's constructor, which keeps backend-specific settings
(model path, speaker WAV for voice cloning, server URL) out of the core.

### Hardware (`tts/device.py`)
`device: auto` picks the first of **CUDA → Apple MPS → CPU** that is available (through torch)
*and* listed in the backend's `supported_devices`. MPS sets `PYTORCH_ENABLE_MPS_FALLBACK=1`
so that unsupported operations fall back to the CPU. An explicit device that isn't
available is an error rather than a silent CPU fallback.

### Shipped backends
* **`kokoro`** (default) — Kokoro-82M at 24 kHz. One `KModel` is shared across per-language `KPipeline`s, and the language comes from the voice prefix (`a`=US English, `b`=UK English, `i`=Italian, `e`, `f`, `p`, `h`, `j`, `z`). Voice blends (`"af_bella,af_heart"`) and custom `.pt` voices work. Small enough for CPU-only machines; much faster on CUDA or MPS. Non-English voices need `espeak-ng`.
* **`openai_http`** — any *local* server that implements `POST /v1/audio/speech` (Kokoro-FastAPI, openedai-speech for XTTS/Piper, AllTalk, LocalAI, …). This puts heavy models such as XTTS-v2 in their own container or on their own GPU box, and keeps torch out of this process.
* **`null`** — tones whose length tracks the text. Used for tests and timing, with no download.

### Extension point: dialogue-native models
Models such as Dia or VibeVoice generate a whole multi-speaker exchange in one pass, which gives
better turn-taking prosody. The planned hook is an optional
`synthesize_dialogue(turns) -> np.ndarray` method. When a backend has it, `render` would send
windows of several turns instead of one turn at a time. This is not implemented yet: the contract
leaves room for it, and the current renderer stays per-turn.

## 7. Resumability and caching

| Artifact | Invalidated when |
|---|---|
| `context/*.json` (cache dir) | `models --refresh` / `--probe`, or a different server, model or `extra_body` |
| `notes.json` | model changes, `--fresh` |
| `outline.json` (also stores finished segments) | style, length, language, speakers or model change; `--fresh` |
| `tts/*.wav` (cache dir) | text, voice, speed or backend change |

A crash in segment 9 of 12 costs only that segment when you resume.

## 8. Testing

`tests/fake_server.py` is a fake OpenWebUI that **emulates Ollama's silent front-truncation**.
The test suite checks that:
* the probe finds the real window despite a 131k "architectural" claim;
* a long paper in a small window goes through notes → outline → multi-part segments without any truncated call;
* metadata that is wrong triggers `ContextTruncatedError` instead of a hallucinated script;
* resuming makes zero LLM calls;
* plugins load by import path, and the Kokoro backend is wired correctly (with a stubbed `kokoro` module);
* the parser, JSON repair, splitting and speech normalisation behave as expected.

Run with `pytest`. A real Kokoro run needs the model download from Hugging Face on first use.

## 9. Limitations and next steps

* Math- and table-heavy papers would benefit from a GROBID/`marker` extractor plugin, since PyMuPDF heuristics lose structure.
* An optional **fact-check pass** could compare each segment's numbers and claims against its source and rewrite mistakes. The checkpoint design makes this a drop-in stage between script and synth.
* Streaming responses would give progress inside long completions. It is not needed for correctness.
* The `synthesize_dialogue` hook for dialogue-native TTS (§6).
* Light pronunciation lexicon per paper (acronyms, model names) applied in `normalize_for_tts`.
