# paper2pod

Turn a scientific PDF into a two-person audio discussion. A remote model behind
**OpenWebUI** (or any OpenAI-compatible server) writes the script; a **local** TTS
model (Kokoro by default, others as plugins) voices it.

## Quick start

Needs Python ≤ 3.12:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e .            # installs everything: CLI + web + Kokoro TTS

# config (copy once, edit model/base_url)
cp config.example.yaml config.yaml

# set your OpenWebUI endpoint
export OPENWEBUI_BASE_URL="https://host/api"
export OPENWEBUI_API_KEY="sk-..."

# start the web app
paper2pod -c config.yaml serve --port 8170   # -> http://127.0.0.1:8170
```

Drag a PDF into the dropzone; the progress bar tracks conversion
(`extract → notes → outline → segments → audio → finalize`). Output lands in `library/<id>/`
and `out/<paper>/`.

Platform notes:

- **NVIDIA**: install a CUDA torch build first — `pip install torch --index-url https://download.pytorch.org/whl/cu124`
- **non-English voices**: `brew install espeak-ng` (macOS) / `apt install espeak-ng`
- **MP3 + chapters**: needs `ffmpeg`
- **English phonemizer**: `python -m spacy download en_core_web_sm` if unresolved

## Configure

| Setting | Env var | YAML |
|---|---|---|
| endpoint | `OPENWEBUI_BASE_URL` | `llm.base_url` |
| api key | `OPENWEBUI_API_KEY` | `llm.api_key` |
| model | `PAPER2POD_MODEL` | `llm.model` |

`llm.model` must be the exact id shown by `paper2pod models`. See `config.example.yaml` for
all options (styles, speakers, voices, TTS, context window). See [DESIGN.md](DESIGN.md) for
how the model's real context window is discovered.

## Use (CLI)

```bash
paper2pod -c config.yaml run paper.pdf --style host_expert --minutes 30   # full pipeline
paper2pod -c config.yaml script paper.pdf                                # script only
paper2pod synth out/paper/script.json                                     # voice a script
paper2pod extract paper.pdf                                               # inspect PDF parse
paper2pod models --model "llama3.1:70b" --probe                            # check context window
paper2pod backends                                                         # list TTS backends
```

Output in `out/<paper>/`: `podcast.mp3` (+`.wav`/`.srt`), `script.md`/`script.json`, and
checkpoints (`paper.json`, `notes.json`, `outline.json`) that let runs resume. `--fresh`
replans from scratch.

## Web API

| endpoint | purpose |
|---|---|
| `POST /api/papers` | upload a PDF (field `pdf`) and convert |
| `GET /api/library` | list papers + progress |
| `GET /api/papers/{id}/status` | poll progress (`{state, stage, progress, message}`) |
| `GET /api/papers/{id}/audio` | the `podcast.mp3` |
| `GET /api/papers/{id}/file?kind=pdf\|srt\|script` | download artifacts |
| `POST /api/papers/{id}/rerun` | regenerate from the stored PDF |
| `DELETE /api/papers/{id}` | delete a paper |

## TTS backends

| backend | what | config |
|---|---|---|
| `kokoro` | Kokoro-82M in-process | `voice: af_heart`, `bm_george`, `if_sara`, … |
| `openai_http` | any local `/v1/audio/speech` server | `options: {base_url, model, sample_rate}` |
| `null` | test tones, no model | — |
| your own | `module:Class` or an entry point in group `paper2pod.tts` | `options:` passed to `__init__` |

## Tests

```bash
pip install -e ".[dev]" && pytest   # fake server + null TTS, no network or model needed
```