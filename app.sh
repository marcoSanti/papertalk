#!/usr/bin/env bash
# Papertalk app: build, run, test, release and versioning.
# Run from anywhere; things that need the Swift package run from client/.
#
#   ./app.sh [build|app|run|release|test|coverage|clean|version]
#   ./app.sh bump-patch|bump-minor|bump-major
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$ROOT/client"

# Version comes from VERSION (see scripts/version.sh); override it for a one-off
# build with VERSION=... (CI uses this for dev builds). The build "number"
# (shown in parentheses in About Papertalk) is the short commit hash the app was
# built from, so any build can be traced to its exact source; override with BUILD_NUMBER=...
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

usage() {
    echo "usage: $0 [build|app|run|release|test|coverage|clean|version|bump-patch|bump-minor|bump-major]" >&2
    exit 2
}

build() {
    local config="$1"
    cd "$CLIENT"
    swift build -c "$config"
}

# Build a runnable .app bundle (dist/Papertalk.app) and optionally zip it.
# config=debug by default; release builds the release binary.
app() {
    local config="${1:-debug}"
    build "$config"
    cd "$CLIENT"
    local app="dist/Papertalk.app" zip_file="dist/Papertalk-$VERSION.zip"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp ".build/$config/Papertalk" "$app/Contents/MacOS/Papertalk"
    cp Sources/Papertalk/Info.plist "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
    if [ -f "$ROOT/shared/icon.icns" ]; then
        cp "$ROOT/shared/icon.icns" "$app/Contents/Resources/Papertalk.icns"
        plutil -replace CFBundleIconFile -string Papertalk "$app/Contents/Info.plist"
    fi
    codesign --force --sign - "$app" >/dev/null 2>&1 || true
    echo "Built $app (version $VERSION, build $BUILD_NUMBER)"
    if [ "${2:-}" = zip ]; then
        rm -f dist/Papertalk-*.zip
        ditto -c -k --keepParent "$app" "$zip_file"
        echo "Bundled $zip_file"
    fi
}

run() {
    app debug
    cd "$CLIENT"
    if pgrep -x Papertalk >/dev/null; then
        echo "Quitting the running Papertalk…"
        osascript -e 'tell application id "dev.papertalk.desktop" to quit' >/dev/null 2>&1 || true
        for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Papertalk >/dev/null || break; sleep 0.5; done
    fi
    echo "Starting Papertalk.app"
    open dist/Papertalk.app
}

# Build a release-optimized .app bundle and zip it into dist/Papertalk-<version>.zip
release() {
    app release zip
}

# Run the PapertalkTests mock test suite (no network, no keychain).
test() {
    cd "$CLIENT"
    swift test --disable-swift-testing
}

# Tests with code coverage → coverage/ (see scripts/coverage.sh).
coverage() {
    "$ROOT/scripts/coverage.sh"
}

clean() {
    cd "$CLIENT"
    swift package clean
    rm -rf dist
}


case "${1:-}" in
    build)   build debug ;;
    app)     app "${2:-debug}" ;;
    run)     run ;;
    release) release ;;  # VERSION=... overrides the file for this build only
    test)    test ;;
    coverage) coverage ;;
    clean)   clean ;;
    version) echo "$VERSION" ;;
    '') usage ;;
    *)   usage ;;
esac