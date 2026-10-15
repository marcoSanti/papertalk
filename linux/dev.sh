#!/usr/bin/env bash
# Run things in the Linux dev container (AGENTS.md, "Linux port"). Needs Docker.
#   linux/dev.sh build | shell | test | app | <command...>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=papertalk-linux-dev
# Linux build products live in their own folder so they never mix with the macOS .build.
RUN=(docker run --rm -v "$ROOT:/src" -v papertalk-linux-build:/src/client/.build-linux
     -v papertalk-linux-cache:/root/.cache -w /src "$IMAGE")

case "${1:-}" in
    build) docker build -t "$IMAGE" -f "$ROOT/linux/Dockerfile" "$ROOT" ;;
    shell) docker run --rm -it -v "$ROOT:/src" -v papertalk-linux-build:/src/client/.build-linux \
               -v papertalk-linux-cache:/root/.cache -w /src "$IMAGE" bash ;;
    # The Swift suite and the Python services' tests, on Linux.
    test)  "${RUN[@]}" bash -lc 'cd client && swift test --disable-swift-testing --scratch-path .build-linux/main && cd ../python && python3 -m pytest -q' ;;
    # Build the Linux app (client/.build-linux/main/debug/Papertalk).
    app)   "${RUN[@]}" bash -lc 'cd client && swift build --scratch-path .build-linux/main' ;;
    '') echo "usage: $0 build | shell | test | app | <command...>" >&2; exit 2 ;;
    *) "${RUN[@]}" bash -lc "$*" ;;
esac
