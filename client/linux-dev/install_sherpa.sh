#!/usr/bin/env bash
# Installs sherpa-onnx's C library (Kokoro text-to-speech on ONNX Runtime) for the Linux
# build: libsherpa-onnx-c-api.so and libonnxruntime.so into $PREFIX/lib (default
# /usr/local). The header is vendored in client/Sources/CSherpaOnnx and must match
# SHERPA_VERSION. Used by the dev image; run it once (as root) to build on a plain machine.
set -euo pipefail
SHERPA_VERSION=1.13.8
PREFIX="${PREFIX:-/usr/local}"
case "$(uname -m)" in
    x86_64)  NAME="linux-x64-shared-lib"
             SHA=3892d184be41027e18165e67f549cd4e4cdd8dcd73ac5579e97afd55e14e30b6 ;;
    aarch64|arm64) NAME="linux-aarch64-shared-cpu-lib"
             SHA=fb98b80628a383909bf83626daca2e0d0ffc93bf1f7d222eaaa4282b388f072f ;;
    *) echo "No sherpa-onnx build for $(uname -m)" >&2; exit 1 ;;
esac
DIR="sherpa-onnx-v$SHERPA_VERSION-$NAME"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/lib.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/$DIR.tar.bz2"
echo "$SHA  $TMP/lib.tar.bz2" | sha256sum -c --quiet
tar -xjf "$TMP/lib.tar.bz2" -C "$TMP"
mkdir -p "$PREFIX/lib"
install -m 644 "$TMP/$DIR/lib/libsherpa-onnx-c-api.so" "$TMP/$DIR/lib/libonnxruntime.so" "$PREFIX/lib/"
# pkg-config tells SwiftPM where the library is (the Swift linker doesn't search /usr/local).
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/sherpa-onnx.pc" <<PC
libdir=$PREFIX/lib

Name: sherpa-onnx
Description: sherpa-onnx C API (speech on ONNX Runtime)
Version: $SHERPA_VERSION
Libs: -L\${libdir} -lsherpa-onnx-c-api -lonnxruntime
Cflags:
PC
command -v ldconfig >/dev/null && ldconfig || true
echo "sherpa-onnx $SHERPA_VERSION installed in $PREFIX/lib"
