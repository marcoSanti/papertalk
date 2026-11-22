#!/usr/bin/env bash
# The MVC check: compiles each lower layer without the layers above it, so a Model that reaches
# into a Controller, or a Presentation that reaches into either Controllers or Views, doesn't
# compile. Run by `app.sh test` and scripts/coverage.sh; ArchitectureTests checks the Views.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Sources/Papertalk"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SWIFTC=(swiftc -swift-version 5 -target "$(uname -m)-apple-macosx26.0" -I "$WORK")

"${SWIFTC[@]}" -emit-module -parse-as-library -module-name PapertalkStore \
    -emit-module-path "$WORK/PapertalkStore.swiftmodule" "$ROOT"/Sources/PapertalkStore/*.swift

# The one thing the Model takes from FluidAudio, so the check needn't build the dependencies.
echo 'enum KokoroAneConstants { static let englishVoices: [String] = [] }' > "$WORK/VoiceList.swift"

MODEL=("$APP/Shared/Models" "$APP/Shared/Support" "$APP/Shared/Localization" "$APP/macOS/Support/CompressedAudio.swift")

# check <layer> <paths…>: those paths must compile by themselves.
check() {
    local layer="$1" files=("$WORK/VoiceList.swift") file
    shift
    while IFS= read -r file; do files+=("$file"); done < <(find "$@" -name '*.swift')
    if ! "${SWIFTC[@]}" -typecheck -wmo -parse-as-library -module-name Layer "${files[@]}" > "$WORK/log" 2>&1; then
        grep -E ' error: ' "$WORK/log" | sort -u >&2 || cat "$WORK/log" >&2
        echo "MVC: $layer depends on a layer above it (see AGENTS.md, \"MVC layers\")." >&2
        exit 1
    fi
}

check Model "${MODEL[@]}"
check Presentation "${MODEL[@]}" "$APP/Shared/Presentation"
echo "MVC layers OK"
