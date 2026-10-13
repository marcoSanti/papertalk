# Papertalk

Turn a scientific PDF into a two-person audio discussion ("a podcast") entirely on one Mac.

The macOS app **extracts the PDF text, writes a podcast script** (via any OpenAI-compatible
chat endpoint — OpenWebUI, LM Studio, llama.cpp, …), and **reads it aloud with on-device
Kokoro neural voices** (Core ML / Neural Engine, via FluidAudio). Optional storage server
for sharing a library across machines.

## Layout

| piece | what it is |
|---|---|
| `client/` | the native SwiftUI macOS app (runs the whole pipeline in-process) |
| `server/storage_server.py` | tiny optional HTTP file store (stdlib-only) for sharing a library across machines |
| `shared/` | shared assets (app icon) |

The pipeline always runs inside the app. The optional storage server just lets a *remote*
library be read/written over HTTP instead of the local disk.

## Quick start

```bash
cd client && ./make-app.sh          # builds Papertalk.app into client/dist/
```

Open `client/dist/Papertalk.app`:

1. **LLM Settings…** (App menu) → point `LLM base URL` at an OpenAI-compatible endpoint
   (default model `llama3.1:70b`). This is stored locally in the app.
2. **File → Open PDF…** (Cmd+O) → upload a paper. Wait for conversion.
3. Press play and the script is read aloud with on-device Kokoro voices
   (first play downloads the models to `~/.cache/fluidaudio`).

Audio is always synthesized live from the transcript with system voices; no audio file is
ever baked.

## Optional: the storage server

By default papers live in the app's Application Support folder. To share the library with
another machine over HTTP (instead of touching the server or SMB everywhere), run the
storage server on a machine with the files:

```bash
python3 server/storage_server.py                 # -> http://<host>:9170
PAPER2POD_STORAGE_TOKEN="sekret" python3 server/storage_server.py   # require a bearer token
```

All stdlib — no dependencies, no venv needed. Files are stored under `~/.paper2pod/storage/`
(override with `PAPER2POD_STORAGE_ROOT`), as plain `papers/<id>/…` artifacts.

Then in the app, **Server Settings…** → set the base URL (leave it empty for local disk) and
token. From then on the pipeline reads/writes that remote library instead of local disk.

## API

`GET /` lists stored keys; `GET`/`PUT`/`DELETE`/`HEAD /<key>` reads/writes/deletes a key;
`GET /` with no token returns the key inventory. Keys are namespaced `papers/<id>/{paper,script,transcript}.json`, `source.pdf`, `podcast.m4a`.