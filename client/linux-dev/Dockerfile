# Linux development image for the Papertalk port (see AGENTS.md, "Linux port").
# Swift toolchain + the C libraries behind the platform shims (sherpa-onnx for Kokoro,
# poppler for PDFs, libsecret for the keyring) + GTK 4 (for the UI), plus Xvfb so the
# UI can run and be screenshotted headless. Python is only for build helpers (the
# AppImage icon, the demo library), never for the app.
#
#   client/linux-dev/dev.sh build      build this image (papertalk-linux-dev)
#   client/linux-dev/dev.sh shell      a shell in it, repo mounted at /src
#   client/linux-dev/dev.sh <cmd...>   run a command in it from /src
FROM swift:6.2-noble

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libgtk-4-dev pkg-config libpoppler-glib-dev libsecret-1-dev bzip2 \
        pipewire-bin pulseaudio-utils alsa-utils libnotify-bin \
        python3 python3-pil \
        xvfb xauth imagemagick dbus-x11 xdotool openbox curl file \
    && rm -rf /var/lib/apt/lists/*

COPY client/linux-dev/install_sherpa.sh /tmp/
RUN /tmp/install_sherpa.sh

WORKDIR /src
