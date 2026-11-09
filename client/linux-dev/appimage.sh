#!/usr/bin/env bash
# Packs the Linux app into client/dist/Papertalk-<version>-<arch>.AppImage.
# Run in the dev container: client/linux-dev/dev.sh appimage
#
#   VERSION=...  version in the file name (default: the VERSION file)
#   CHANNEL=...  stable for the official icon, dev (default) for the DEV ribbon
#
# The AppImage is self-contained except for GTK 4 and the C library, which
# come from the system: it carries the release binary (Swift runtime linked
# statically) and the shared libraries it needs beyond the desktop's own:
# sherpa-onnx and ONNX Runtime (Kokoro), poppler (PDFs) and libsecret (the
# keyring). No Python. Kokoro's model is downloaded on first use, as on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
CHANNEL="${CHANNEL:-dev}"
ARCH="$(uname -m)"
APPIMAGETOOL_VERSION=1.9.1

case "$CHANNEL" in stable|dev) ;; *) echo "CHANNEL must be stable or dev, not '$CHANNEL'" >&2; exit 2 ;; esac

BUILD="$ROOT/client/.build-linux"
APPDIR="$BUILD/AppDir"
DIST="$ROOT/client/dist"
OUT="$DIST/Papertalk-$VERSION-$ARCH.AppImage"

echo "== Building the release binary"
# -num-threads: whole-module optimisation otherwise generates code for the app's module on one
# core (an incremental release build: 36 s single-threaded, 23 s on 32 threads).
(cd "$ROOT/client" && swift build -c release --static-swift-stdlib --scratch-path .build-linux/release \
    -Xswiftc -num-threads -Xswiftc "$(nproc)" 2>&1 \
    | grep -E "error|warning: .*Sources/Papertalk|Build complete")
BIN="$ROOT/client/.build-linux/release/release/Papertalk"

echo "== Assembling the AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib"
install -m 755 "$BIN" "$APPDIR/usr/bin/Papertalk"
strip "$APPDIR/usr/bin/Papertalk"

# Shared libraries: bundle every dependency of the binary, except what any
# desktop with GTK 4 provides (glibc, the C++ runtime and the GTK / graphics /
# X / Wayland stack): those must come from the system to match its drivers and
# themes.
SYSTEM_LIBS='^(linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|librt\.so|libpthread\.so|libresolv\.so|libutil\.so|libgcc_s|libstdc\+\+|libgtk-4|libgdk|libglib|libgio|libgobject|libgmodule|libgthread|libpango|libcairo|libharfbuzz|libfontconfig|libfreetype|libfribidi|libthai|libdatrie|libgraphite2|libgraphene|libepoxy|libvulkan|libEGL|libGL|libgbm|libdrm|libwayland|libxkbcommon|libX|libxcb|libpixman|libpng16|libjpeg|libtiff|libwebp|libsharpyuv|libLerc|libjbig|libdeflate|libz\.|libexpat|libffi|libpcre2|libmount|libblkid|libselinux|libbz2|liblzma|libzstd|libbrotli|libbsd|libmd\.so|liblzo2)'
bundle_deps() {
    ldd "$1" 2>/dev/null | awk '/=> \// {print $3}' | while read -r lib; do
        case "$lib" in "$APPDIR"/*) continue ;; esac
        name="$(basename "$lib")"
        if ! echo "$name" | grep -qE "$SYSTEM_LIBS" && [ ! -e "$APPDIR/usr/lib/$name" ]; then
            cp -L "$lib" "$APPDIR/usr/lib/$name"
        fi
    done
}
# ldd lists the whole tree (poppler's and sherpa-onnx's own dependencies too).
bundle_deps "$APPDIR/usr/bin/Papertalk"
echo "Bundled $(ls "$APPDIR/usr/lib" | grep -c '\.so') shared libraries"

cat > "$APPDIR/AppRun" <<APPRUN
#!/bin/sh
# Papertalk's launcher: the bundled libraries first, then the app.
HERE="\$(dirname "\$(readlink -f "\$0")")"
export LD_LIBRARY_PATH="\$HERE/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$HERE/usr/bin/Papertalk" "\$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

cat > "$APPDIR/papertalk.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Papertalk
Comment=Turn research papers into podcasts
Exec=Papertalk %f
Icon=papertalk
Terminal=false
Categories=Education;AudioVideo;Audio;
MimeType=application/pdf;
X-AppImage-Version=$VERSION
DESKTOP
python3 "$ROOT/client/linux-dev/icon_png.py" "$ROOT/shared/icon.icns" "$APPDIR/papertalk.png" "$CHANNEL" 256 >/dev/null
ln -sf papertalk.png "$APPDIR/.DirIcon"

echo "== Packing"
TOOL="$HOME/.cache/papertalk/appimagetool-$APPIMAGETOOL_VERSION-$ARCH.AppImage"
if [ ! -x "$TOOL" ]; then
    mkdir -p "$(dirname "$TOOL")"
    curl -fsSL -o "$TOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$ARCH.AppImage"
    chmod +x "$TOOL"
fi
mkdir -p "$DIST"
rm -f "$DIST"/Papertalk-*-"$ARCH".AppImage
# No FUSE in containers: let the tool run from its own extracted copy.
ARCH="$ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --no-appstream "$APPDIR" "$OUT" 2>&1 | grep -vE "^\s*$" | tail -3
echo "Built $OUT ($(du -h "$OUT" | cut -f1), $CHANNEL icon)"
