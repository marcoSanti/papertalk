# paper2pod — self-contained image (LLM calls only need the internet).
#
#   docker build -t paper2pod .
#   docker run -d --name paper2pod -p 8170:8170 \
#     -v /path/to/unraid/share:/library \
#     -e OPENWEBUI_BASE_URL=... -e OPENWEBUI_API_KEY=... \
#     paper2pod
#
# The library lives OUTSIDE the container, on the mounted /library volume (an
# Unraid share). Put a config.yaml in the library root (auto-detected) or point
# the LLM endpoint/key via env vars / the Settings gear. Model weights are baked
# in at build time so the runtime never needs to download them.

# Kokoro/misaki require Python < 3.13.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/app/.cache/huggingface \
    PAPER2POD_LIBRARY=/library \
    PAPER2POD_SETTINGS=/library/settings.json \
    HOME=/app

WORKDIR /app

# System deps: ffmpeg (MP3 + chapters), espeak-ng (Kokoro phonemes/voices),
# libsndfile (soundfile), git (model/pipeline downloads). Tailscale is pulled
# from its official apt repo so the web UI can be reached over the tailnet.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ffmpeg espeak-ng libsndfile1 git curl sudo \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.gpg \
       -o /tmp/tailscale.gpg \
    && install -o root -g root -m 644 /tmp/tailscale.gpg \
       /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] \
https://pkgs.tailscale.com/stable/debian bookworm main" \
       > /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/* /tmp/tailscale.gpg

# Install the app and its dependencies (torch runs on CPU here; pass a CUDA
# --build-arg to use a GPU build on the NAS if desired).
COPY pyproject.toml README.md config.example.yaml ./
COPY src ./src
RUN pip install .

# Bake in the Kokoro model + pipelines so the running container needs no network
# for TTS. The cache lands in /app/.cache, warmed here (and reapplied on each
# container up via the image's writable layer), before the app starts.
RUN python - <<'EOF'
from paper2pod.tts.kokoro_backend import KokoroBackend
b = KokoroBackend(device="cpu")
for v in ("af_heart", "bm_george"):
    b.synthesize("Hello from paper2pod.", v, 1.0)
print("Kokoro warmed:", b.list_voices()[:3], "...")
EOF

# Runs as root on purpose: the mounted Unraid share / library directory is
# owned by the host, and root is the only uid guaranteed to write to it. This is
# a self-contained, single-user local app, so that trade-off is acceptable here.
# If your library lives on a share writable by a non-root uid, set `USER 1000`
# to harden it.

# The library MUST be mounted from the host (the Unraid share), e.g.
#   -v /mnt/user/appdata/paper2pod:/library
# The library holds everything persistent: the papers, your <library>/config.yaml
# (auto-discovered), and <library>/settings.json (web-UI settings). Nothing
# application-state lives in the container. No VOLUME is declared here on
# purpose: if the operator forgets the mount, an anonymous volume would silently
# swallow the data instead of keeping it on the share. Unmounted, everything is
# ephemeral (lost on container recreate).

EXPOSE 8170

# No config.yaml by default: the web UI's Settings gear (or env vars) configure
# the LLM endpoint/key. `paper2pod-server` runs the web server only.
CMD ["paper2pod-server"]