# paper2pod

Turn a scientific PDF into a two-person audio discussion. A remote model behind
**OpenWebUI** (or any OpenAI-compatible server) writes the script; a **local** TTS
model (Kokoro by default, others as plugins) voices it.

## Quick start

Needs Python ≤ 3.12:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e .            # installs everything: web server + Kokoro TTS

# start the web app (config.yaml + env vars are picked up automatically)
paper2pod-server            # -> http://0.0.0.0:8170  (bind via PAPER2POD_HOST)
```

Drag a PDF into the dropzone; the progress bar tracks conversion
(`extract → notes → outline → segments → audio → finalize`). Output lands in `library/<id>/`
and `out/<paper>/`.

### Configuration

`config.yaml` is loaded automatically from the current directory, `~/.config/paper2pod/config.yaml`,
**or inside the library folder** (`<library>/config.yaml`, e.g. a sidecar next to a mounted
library share). You don't need the `-c` flag. If no `config.yaml` is found, open the **Settings**
gear button in the web UI to set the LLM endpoint, API key and model — or set them with env vars:

```bash
# set your OpenWebUI endpoint (either route works)
export OPENWEBUI_BASE_URL="https://host/api"
export OPENWEBUI_API_KEY="sk-..."
```

Copy `config.example.yaml` → `config.yaml` for the full option surface (styles, speakers,
voices, TTS, context window). Precedence: **env vars > config.yaml > web UI
settings > defaults**.

Platform notes:

- **NVIDIA**: install a CUDA torch build first — `pip install torch --index-url https://download.pytorch.org/whl/cu124`
- **non-English voices**: `brew install espeak-ng` (macOS) / `apt install espeak-ng`
- **MP3 + chapters**: needs `ffmpeg`
- **English phonemizer**: `python -m spacy download en_core_web_sm` if unresolved

## Docker (NAS / Unraid)

A self-contained image is provided — it bundles Python 3.12, torch, and even the Kokoro
TTS model weights (warmed at build time), so the running container only needs the internet
for live LLM calls. Everything persistent lives in one library folder on a mounted share.

```bash
docker build -t paper2pod .
docker run -d --name paper2pod -p 8170:8170 \
  -v /mnt/user/appdata/paper2pod:/library \
  -e OPENWEBUI_BASE_URL="https://host/api" -e OPENWEBUI_API_KEY="sk-..." \
  paper2pod
```

The server listens on `0.0.0.0` by default (set `PAPER2POD_HOST` or `--host` to
bind a specific address, e.g. `127.0.0.1` for loopback-only). In a container the
`-p` port mapping reaches the web UI at `http://<host-ip>:8170`.

- The **library directory is `/library`**, mounted from the host (your Unraid share).
  Keep it on the share so container re-creates don't lose papers:
  ```
  /mnt/user/appdata/paper2pod/
  ├── config.yaml      # your settings (auto-loaded)
  ├── settings.json    # web-UI settings (auto-persisted)
  └── <paper-id>/      # each paper
  ```
  `config.yaml` and `settings.json` both live with the library and persist across re-creates.
- **LLM endpoint/key/model** can be given via env vars (`OPENWEBUI_BASE_URL`,
  `OPENWEBUI_API_KEY`, `PAPER2POD_MODEL`), dropped in `config.yaml`, or set in the
  **Settings gear** in the web UI. Precedence: CLI > env > `config.yaml` > web settings >
  defaults.
- The image **runs as root** so it can write to an Unraid share regardless of host
  ownership. For a non-root-writable library, set `USER 1000` in the Dockerfile.
- `docker run` without `-v` leaves the library ephemeral on purpose (no anonymous volume
  hides your data); always mount the share.

## Configure

| Setting | Env var | YAML |
|---|---|---|
| endpoint | `OPENWEBUI_BASE_URL` | `llm.base_url` |
| api key | `OPENWEBUI_API_KEY` | `llm.api_key` |
| model | `PAPER2POD_MODEL` | `llm.model` |

`llm.model` must be the exact id shown by `paper2pod models`. See `config.example.yaml` for
all options (styles, speakers, voices, TTS, context window). See [DESIGN.md](DESIGN.md) for
how the model's real context window is discovered.

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
| `PATCH /api/papers/{id}/meta` | edit `{title, filename, authors, affiliations, doi, tags, favorite, read}` (manual metadata survives re-runs) |
| `GET /api/settings` / `PUT /api/settings` | read / write the web UI's LLM + TTS settings |

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