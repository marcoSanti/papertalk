#!/usr/bin/env bash
# Run the spike under Xvfb and screenshot it as the demo steps run.
set -e
OUT=/src/client/.build-linux/spike-gtk/shots; mkdir -p "$OUT"
python3 -c "import sys; sys.path.insert(0,'/src/python'); from papertalk_platform import pdf; open('/tmp/cover.png','wb').write(pdf.cover_png(open('/src/linux/spikes/python-services/hello.pdf','rb').read(), 140))"
Xvfb :99 -screen 0 1000x640x24 & XV=$!
export DISPLAY=:99 GDK_BACKEND=x11 SPIKE_DEMO=1 SPIKE_COVER=/tmp/cover.png NO_AT_BRIDGE=1
sleep 1
dbus-launch /src/client/.build-linux/spike-gtk/debug/SpikeGTK > "$OUT/app.log" 2>&1 & APP=$!
for t in 1 4 7 10; do sleep 3; import -window root "$OUT/shot-$t.png"; done
kill $APP $XV 2>/dev/null || true
tail -5 "$OUT/app.log"; ls "$OUT"
