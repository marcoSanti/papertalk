#!/usr/bin/env bash
# Smoke test for the AppImage on a clean system: plain Ubuntu 24.04 with only
# the GTK 4 runtime and an X server, no Swift and no Python. Starts the
# AppImage on a demo library and checks that it stays up and renders the
# covers (that needs the bundled Python and pypdfium2), saving a screenshot to
# client/dist/appimage-smoke.png. Runs on the host (needs Docker), after
# client/linux-dev/dev.sh appimage.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPIMAGE="$(ls "$ROOT"/client/dist/Papertalk-*-"$(uname -m | sed 's/arm64/aarch64/')".AppImage 2>/dev/null | head -1)"
[ -n "$APPIMAGE" ] || { echo "No AppImage in client/dist: run client/linux-dev/dev.sh appimage first" >&2; exit 1; }

# The demo library (from the dev image, which has Python) goes next to the AppImage.
"$ROOT/client/linux-dev/dev.sh" 'rm -rf client/dist/smoke-library && python3 client/linux-dev/demo_library.py client/dist/smoke-library >/dev/null'

docker run --rm -v "$ROOT/client/dist:/dist" ubuntu:24.04 bash -c '
set -e
apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    libgtk-4-1 xvfb xauth imagemagick dbus-x11 ca-certificates xdotool >/dev/null
export HOME=/tmp/home && mkdir -p $HOME/.local/share/papertalk
cp -r /dist/smoke-library/papers $HOME/.local/share/papertalk/
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
export DISPLAY=:99 GDK_BACKEND=x11 NO_AT_BRIDGE=1 GTK_A11Y=none APPIMAGE_EXTRACT_AND_RUN=1
sleep 1
dbus-launch /dist/'"$(basename "$APPIMAGE")"' > /tmp/app.log 2>&1 & APP=$!
sleep 12
kill -0 $APP || { echo "The app exited:"; cat /tmp/app.log; exit 1; }
# Close the first-run setup (its Close button) to see the library and its covers.
xdotool mousemove 385 404 click 1; sleep 3
kill -0 $APP || { echo "The app exited:"; cat /tmp/app.log; exit 1; }
import -window root /dist/appimage-smoke.png
grep -iE "error|traceback|fatal" /tmp/app.log | grep -v DRI3 | head -5 || true
echo "AppImage is running; screenshot in client/dist/appimage-smoke.png"
'
