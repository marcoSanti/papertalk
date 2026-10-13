# paper2pod

Turn a scientific PDF into a two-person audio discussion (a "podcast").

A remote model behind **OpenWebUI** (or any OpenAI-compatible server) writes the script; a
**local** TTS model (Kokoro by default, others as plugins) voices it. All papers live in a
library folder; the web UI and a desktop app both read/write that same library through an
HTTP API.

---

## 1 · What you run

There are two pieces:

| piece | what it does |
|---|---|
| **server** | owns the library, runs the PDF→podcast pipeline, queries the remote LLM, exposes the HTTP API. Runs anywhere Python runs (laptop or Docker on a NAS). |
| **desktop / web UI** | the presentation layer. Loads the same UI and points it at a server — local, or on another machine. |

The pipeline runs on the **server**; the UI is just a window onto it.

---

## 2 · Quick start (run locally)

Needs Python ≤ 3.12:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e .                 # web server + Kokoro TTS + CLI
paper2pod-server                 # -> http://localhost:8170
```

Open http://localhost:8170, drag a PDF into the dropzone, and watch the progress bar.
Each paper becomes `library/<id>/` (PDF, script, audio, metadata) and `out/<paper>/`.

### Desktop app instead of the browser

```bash
cd desktop && npm install && npm start
```

It opens the same UI (loaded from disk) and talks to a server. Default
`http://localhost:8170/api`; change it under **App → Server settings…** (Cmd/Ctrl+,) if your
server is elsewhere. Running a server locally for the desktop:

```bash
./venv/bin/paper2pod serve --host 127.0.0.1 --port 8170   # loopback-only, good for debug
```

---

## 3 · Deploy the server (Docker, e.g. on a NAS)

The image bundles Python 3.12, torch, and the Kokoro weights, so the running container only
needs the internet for live LLM calls. The library lives on a mounted share (re-creating the
container doesn't lose papers):

```bash
docker build -t paper2pod .
docker run -d --name paper2pod -p 8170:8170 \
  -v /mnt/user/appdata/paper2pod:/library \
  -e OPENWEBUI_BASE_URL="https://host/api" -e OPENWEBUI_API_KEY="sk-..." \
  paper2pod
```

Notes:

- **Library = `/library`**, mounted from the host. Keep `config.yaml` and `settings.json`
  there too so they persist across container re-creates:
  ```
  /mnt/user/appdata/paper2pod/
  ├── config.yaml      # your settings (auto-loaded)
  ├── settings.json    # web-UI settings (auto-persisted)
  └── <paper-id>/      # each paper
  ```
- The server binds `0.0.0.0` so the desktop (or a browser) can reach it at
  `http://<host-ip>:8170`. Set `PAPER2POD_HOST`/`--host` to bind elsewhere (e.g. `127.0.0.1`).
- The image runs as **root** so it can write to an Unraid share; set `USER 1000` in the
  Dockerfile if your library is non-root-writable.
- Never run without `-v` — that leaves the library ephemeral by design.

### Optional server hardening (API token)

```bash
PAPER2POD_API_TOKEN="sekret"   # require a bearer token on every /api call
PAPER2POD_CORS_ORIGINS="*"     # allowed origins; default is all
```

Enter the same token in the desktop under **Server settings…**. (Media/SSE URLs may use
`?token=` because those requests can't set headers.)

---

## 4 · Configuration

`config.yaml` is auto-loaded from the current directory, `~/.config/paper2pod/config.yaml`,
or **inside the library** (`<library>/config.yaml` — handy as a sidecar next to a mounted
share). No `-c` flag needed. If there's no `config.yaml`, use the **Settings gear** in the UI
or env vars:

```bash
export OPENWEBUI_BASE_URL="https://host/api"
export OPENWEBUI_API_KEY="sk-..."
```

Copy `config.example.yaml` → `config.yaml` for the full surface (styles, speakers, voices,
TTS, context window). **Precedence: env vars > config.yaml > web-UI settings > defaults.**

Common settings:

| Setting | Env var | YAML |
|---|---|---|
| endpoint | `OPENWEBUI_BASE_URL` | `llm.base_url` |
| api key | `OPENWEBUI_API_KEY` | `llm.api_key` |
| model | `PAPER2POD_MODEL` | `llm.model` |

`llm.model` must be the exact id shown by `paper2pod models`. How the real context window is
discovered is described in [DESIGN.md](DESIGN.md).

### Platform notes

- **NVIDIA**: install a CUDA torch build first — `pip install torch --index-url https://download.pytorch.org/whl/cu124`
- **non-English voices**: `brew install espeak-ng` (macOS) / `apt install espeak-ng`
- **MP3 + chapters**: needs `ffmpeg`
- **English phonemizer**: `python -m spacy download en_core_web_sm` if unresolved

---

## 5 · Web API

| endpoint | purpose |
|---|---|
| `POST /api/papers` | upload a PDF (field `pdf`) and convert |
| `GET /api/library` | list papers + progress (`?limit=`/`?offset=` paginate) |
| `GET /api/papers/{id}/status` | poll progress (`{state, stage, progress, message}`) |
| `GET /api/papers/{id}/audio` | the `podcast.mp3` |
| `GET /api/papers/{id}/file?kind=pdf\|srt\|script` | download artifacts |
| `POST /api/papers/{id}/rerun` | regenerate from the stored PDF |
| `DELETE /api/papers/{id}` | delete a paper |
| `PATCH /api/papers/{id}/meta` | edit `{title, …}` — manual metadata survives re-runs |
| `GET`/`PUT /api/settings` | read / write the UI's LLM + TTS settings |

---

## 6 · TTS backends

| backend | what | config |
|---|---|---|
| `kokoro` | Kokoro-82M in-process | `voice: af_heart`, `bm_george`, `if_sara`, … |
| `openai_http` | any local `/v1/audio/speech` server | `options: {base_url, model, sample_rate}` |
| `null` | test tones, no model | — |
| your own | `module:Class` or an entry point in group `paper2pod.tts` | `options:` passed to `__init__` |

---

## 7 · Tests

```bash
pip install -e ".[dev]" && pytest   # fake server + null TTS, no network or model needed
```