#!/usr/bin/env bash
# Look at the Linux UI headless: builds the app, seeds a demo library in a
# throwaway HOME, runs it under Xvfb and saves screenshots to
# client/.build-linux/shots/. Run in the container: client/linux-dev/dev.sh screenshot
# Optional PAPERTALK_UI_SCRIPT=<file> runs xdotool commands between shots.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/client/.build-linux/shots"; rm -rf "$OUT"; mkdir -p "$OUT"
(cd "$ROOT/client" && swift build --scratch-path .build-linux/main 2>&1 | grep -E "error|Build complete")

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export HOME="$(mktemp -d)"; unset XDG_DATA_HOME XDG_CONFIG_HOME
python3 "$ROOT/client/linux-dev/demo_library.py" "$HOME/.local/share/papertalk"

Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 & XV=$!
export DISPLAY=:99 GDK_BACKEND=x11 NO_AT_BRIDGE=1 GTK_A11Y=none
sleep 1
dbus-launch "$ROOT/client/.build-linux/main/debug/Papertalk" > "$OUT/app.log" 2>&1 & APP=$!
sleep 4
import -window root "$OUT/1-start.png"
if [ -n "${PAPERTALK_UI_SCRIPT:-}" ]; then
    n=2
    while read -r line; do
        [ -z "$line" ] && continue
        if [ "$line" = "shot" ]; then sleep 1.5; import -window root "$OUT/$n.png"; n=$((n+1)); else eval "xdotool $line"; fi
    done < "$PAPERTALK_UI_SCRIPT"
fi
kill $APP $XV 2>/dev/null || true
echo "Screenshots in $OUT:"; ls "$OUT"
