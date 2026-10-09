# paper2pod

Turn a scientific PDF into a detailed two-person audio discussion.
A remote model behind **OpenWebUI** (or any OpenAI-compatible server) writes the script,
taking that model's real context window into account. A **local** TTS model (Kokoro by
default, others as plugins) voices it on CUDA, Apple Silicon, or CPU.

See [DESIGN.md](DESIGN.md) for the architecture.

## Web UI (recommended)

`paper2pod` ships with a local web app: upload a PDF, watch a live progress bar as it converts,
then play the finished episode in the browser. It stores the original PDF and every generated
artifact (audio, subtitles, script) in a `library/` folder.

```bash
# 1) install the app + web server + Kokoro TTS — one time.
#    Kokoro needs Python <= 3.12 (this project's venv is built on 3.12):
#      uv venv --python 3.12 venv --clear
#    then:
./venv/bin/python -m pip install -e ".[web,kokoro]"
#    Kokoro's English phonemizer also needs the spaCy model (if the pip index
#    can't resolve it, use the official wheel):
./venv/bin/python -m spacy download en_core_web_sm   # or:
./venv/bin/python -m pip install "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

# 2) start the server
./venv/bin/paper2pod -c config.yaml serve --port 8170
#    -> Serving web UI on http://127.0.0.1:8170

# 3) open:
#    http://127.0.0.1:8170
```

Then drag a PDF into the dropzone. The progress bar tracks the conversion stages
(`extract → notes → outline → segments → audio → finalize`); when it completes you can play,
download the PDF/subtitles/script, rerun, or delete each paper. Papers are stored under
`./library/<id>/` (override with the `PAPER2POD_LIBRARY` env var). Startup is powered by the
same `llm`/`tts` settings in `config.yaml`.

The API surface is:

| endpoint | purpose |
|---|---|
| `POST /api/papers` | upload a PDF (multipart field `pdf`) and start conversion |
| `GET /api/library` | list stored papers + their progress state |
| `GET /api/papers/{id}/status` | poll conversion progress (`{state, stage, progress, message}`) |
| `GET /api/papers/{id}/audio` | the generated `podcast.mp3` |
| `GET /api/papers/{id}/file?kind=pdf\|srt\|script` | download the original/sidecar files |
| `POST /api/papers/{id}/rerun` | regenerate a paper from its stored PDF |
| `DELETE /api/papers/{id}` | delete a paper |

## CLI (optional)

The same pipeline runs from the command line. First install the runtime (the web UI does not
need this — `notebook` for heavier audio needs torch):

```bash
python -m venv .venv && source .venv/bin/activate
# 1) torch for your hardware (skip if you only use the openai_http TTS backend)
pip install torch                      # macOS (MPS) / CPU
# pip install torch --index-url https://download.pytorch.org/whl/cu124   # NVIDIA
# 2) this package with Kokoro
pip install -e ".[kokoro]"
# non-English Kokoro voices also need espeak-ng (apt install espeak-ng / brew install espeak-ng)
# ffmpeg is needed for MP3 + chapters (otherwise WAV only)
```

Usage commands are under [Use](#use) below.

## Configure

```bash
export OPENWEBUI_BASE_URL="https://your-openwebui.example.org/api"
export OPENWEBUI_API_KEY="sk-..."            # OpenWebUI → Settings → Account → API keys
cp config.example.yaml config.yaml           # optional, for styles/voices/TTS options
```

Check the model and its **effective** context window:

```bash
paper2pod models                              # list models
paper2pod models --model "llama3.1:70b" --probe
# e.g. → Model llama3.1:70b: context window 8192 tokens (source: probe, reliable: True)
#   - ollama arch_max=131072 modelfile num_ctx=None requested num_ctx=None
#   - probe passed at 8192 tokens
```

If an Ollama model shows a small window, raise `num_ctx` for the model in OpenWebUI, or set
`llm.extra_body: {options: {num_ctx: 32768}}` and probe again.

## Use

```bash
# full pipeline
paper2pod -c config.yaml run paper.pdf --model "llama3.1:70b" --style host_expert --minutes 30

# journal-club style between two researchers
paper2pod run paper.pdf --model "llama3.1:70b" --style peers

# two steps: generate, review/edit out/paper/script.json, then synthesise
paper2pod script paper.pdf --model "llama3.1:70b"
paper2pod synth out/paper/script.json --device mps --voices af_heart,bm_george

# inspect PDF structure detection
paper2pod extract paper.pdf
```

Output in `out/<paper>/`: `podcast.mp3` (with chapters), `podcast.wav`, `podcast.srt`,
`script.md`, `script.json`, plus checkpoints (`paper.json`, `notes.json`, `outline.json`).
Re-running resumes from the checkpoints. `--fresh` replans from scratch.

## TTS backends

```bash
paper2pod backends          # lists devices + registered backends
```

| backend | what | config |
|---|---|---|
| `kokoro` | Kokoro-82M in-process (CUDA/MPS/CPU) | `voice: af_heart`, `bm_george`, `if_sara`, … |
| `openai_http` | any local `/v1/audio/speech` server (Kokoro-FastAPI, XTTS via openedai-speech, …) | `options: {base_url, model, sample_rate}` |
| `null` | test tones, no model | — |
| your own | `module:Class` or an entry point in group `paper2pod.tts` | `options:` passed to `__init__` |

Writing a plugin:

```python
# my_piper.py
import subprocess, tempfile
import soundfile as sf
from paper2pod.tts import TTSBackend

class PiperBackend(TTSBackend):
    name = "piper"
    supported_devices = ("cpu",)

    @property
    def sample_rate(self): return 22050

    def synthesize(self, text, voice, speed=1.0):
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            subprocess.run(["piper", "--model", voice, "--output_file", f.name,
                            "--length_scale", str(1 / speed)], input=text.encode(), check=True)
            audio, _ = sf.read(f.name, dtype="float32")
        return audio
```
```yaml
tts: {backend: "my_piper:PiperBackend"}
script:
  speakers:
    host_expert:
      - {name: Alex, role: host,   voice: en_US-amy-medium.onnx, persona: "..."}
      - {name: Sam,  role: expert, voice: en_US-ryan-high.onnx,  persona: "..."}
```

## Tests

```bash
pip install -e ".[dev]" && pytest
```
The tests use a fake OpenWebUI server that copies Ollama's silent prompt truncation, and the
`null` TTS backend, so no network or model is needed.
