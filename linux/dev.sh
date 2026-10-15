#!/usr/bin/env bash
# Run things in the Linux dev container (docs/LINUX_PORT.md). Needs Docker.
#   linux/dev.sh build | shell | <command...>
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
    '') echo "usage: $0 build | shell | <command...>" >&2; exit 2 ;;
    *) "${RUN[@]}" bash -lc "$*" ;;
esac
