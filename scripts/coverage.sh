#!/usr/bin/env bash
# Run the test suite with code coverage and write the results to coverage/ at
# the repo root (git-ignored): report.txt (llvm-cov table), lcov.info (for
# editors and other tools), summary.md and totals.json.
# Uses only the Xcode toolchain and python3: no external service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/coverage"
cd "$ROOT/client-macos"

swift test --disable-swift-testing --enable-code-coverage

# Locate the outputs instead of assuming a layout: SwiftPM's two build systems
# use different folders (.build/out/Products/Debug vs .build/<arch>/debug) and
# name the test bundle differently (PapertalkTests.xctest vs
# PapertalkPackageTests.xctest), and which one runs depends on the Xcode version.
PROFDATA="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
BIN_DIR="$(swift build --show-bin-path)"
XCTEST="$(find "$BIN_DIR" -maxdepth 1 -name '*.xctest' -type d | head -n 1)"
BIN="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"
if [[ -z "$XCTEST" || ! -f "$BIN" || ! -f "$PROFDATA" ]]; then
    echo "Coverage data not found." >&2
    echo "  test bundle: ${XCTEST:-<no .xctest in $BIN_DIR>}" >&2
    echo "  profile:     $PROFDATA" >&2
    exit 1
fi

# Only the app's own sources: not the tests, not dependencies.
IGNORE='(\.build|Tests)/'
mkdir -p "$OUT"
xcrun llvm-cov report "$BIN" -instr-profile "$PROFDATA" -ignore-filename-regex="$IGNORE" > "$OUT/report.txt"
xcrun llvm-cov export "$BIN" -instr-profile "$PROFDATA" -ignore-filename-regex="$IGNORE" -format=lcov > "$OUT/lcov.info"
xcrun llvm-cov export "$BIN" -instr-profile "$PROFDATA" -ignore-filename-regex="$IGNORE" -summary-only > "$OUT/summary.json"

python3 -I "$ROOT/scripts/coverage_summary.py" "$OUT/summary.json" "$OUT"
echo "Wrote $OUT (report.txt, lcov.info, summary.md)"
