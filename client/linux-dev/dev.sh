#!/usr/bin/env bash
# Run things in the Linux dev container (AGENTS.md, "Linux port"). Needs Docker.
#   client/linux-dev/dev.sh build | shell | test | e2e | app | <command...>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE=papertalk-linux-dev
# Linux build products live in their own folder so they never mix with the macOS .build.
RUN=(docker run --rm -v "$ROOT:/src" -v papertalk-linux-build:/src/client/.build-linux
     -v papertalk-linux-cache:/root/.cache -w /src "$IMAGE")

case "${1:-}" in
    build) docker build -t "$IMAGE" -f "$ROOT/client/linux-dev/Dockerfile" "$ROOT" ;;
    shell) docker run --rm -it -v "$ROOT:/src" -v papertalk-linux-build:/src/client/.build-linux \
               -v papertalk-linux-cache:/root/.cache -w /src "$IMAGE" bash ;;
    # The Swift suite and the Python services' tests, on Linux.
    test)  "${RUN[@]}" bash -lc 'cd client && swift test --disable-swift-testing --scratch-path .build-linux/main && cd ../python && python3 -m pytest -q' ;;
    # The opt-in end-to-end import test: real PDF, Kokoro and WAVs, mocked LLM.
    e2e)   "${RUN[@]}" bash -lc 'cd client && PAPERTALK_E2E=1 LLM_BASE_URL=http://llm.mock/v1 PAPERTALK_MODEL=m swift test --disable-swift-testing --scratch-path .build-linux/main --filter EndToEndImportTests' ;;
    # Build the Linux app (client/.build-linux/main/debug/Papertalk).
    app)   "${RUN[@]}" bash -lc 'cd client && swift build --scratch-path .build-linux/main' ;;
    '') echo "usage: $0 build | shell | test | e2e | app | <command...>" >&2; exit 2 ;;
    *) "${RUN[@]}" bash -lc "$*" ;;
esac
