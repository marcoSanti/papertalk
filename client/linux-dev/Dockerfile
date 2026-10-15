# Linux development image for the Papertalk port (see AGENTS.md, "Linux port").
# Swift toolchain + Python (for the platform services) + GTK 4 (for the UI),
# plus Xvfb so the UI can run and be screenshotted headless.
#
#   client/linux-dev/dev.sh build      build this image (papertalk-linux-dev)
#   client/linux-dev/dev.sh shell      a shell in it, repo mounted at /src
#   client/linux-dev/dev.sh <cmd...>   run a command in it from /src
FROM swift:6.2-noble

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev libpython3-dev \
        libgtk-4-dev pkg-config \
        libsndfile1 pipewire-bin pulseaudio-utils alsa-utils libnotify-bin \
        xvfb xauth imagemagick dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# The Python side of the platform services lives in a venv, like it will on users' machines.
ENV PAPERTALK_VENV=/opt/papertalk-venv
COPY python/requirements.txt python/requirements-dev.txt /tmp/
RUN python3 -m venv "$PAPERTALK_VENV" \
    && "$PAPERTALK_VENV/bin/pip" install --no-cache-dir -r /tmp/requirements-dev.txt
ENV PATH="$PAPERTALK_VENV/bin:$PATH"

WORKDIR /src
