#!/usr/bin/env bash
# Papertalk app: build, run, test, release and versioning.
# Run from anywhere; things that need the Swift package run from client/.
#
#   ./app.sh [build|app|run|release|test|coverage|clean|version]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$ROOT/client"

VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

# Which icon the app gets. Only official releases (the release workflow passes
# CHANNEL=stable for a version bump) use the official icon; every other build,
# local debug builds and the dev pre-releases of main included, gets the
# "DEV" stripe version so the two are easy to tell apart.
CHANNEL="${CHANNEL:-dev}"
case "$CHANNEL" in
    stable|dev) ;;
    *) echo "CHANNEL must be stable or dev, not '$CHANNEL'" >&2; exit 2 ;;
esac
OFFICIAL_ICON="$ROOT/shared/icon.icns"
DEV_ICON="$CLIENT/.build/icons/Papertalk-dev.icns"
DOCUMENT_ICON="$CLIENT/.build/icons/PaperDocument.icns"

usage() {
    echo "usage: $0 [build|app|run|release|test|coverage|clean|version]" >&2
    exit 2
}

# The icon for this CHANNEL. The dev icon is generated from the official one,
# and regenerated when either it or the script is newer.
icon() {
    if [ "$CHANNEL" = stable ]; then
        echo "$OFFICIAL_ICON"
        return
    fi
    local script="$ROOT/scripts/dev_icon.swift"
    if [ ! -f "$DEV_ICON" ] || [ "$OFFICIAL_ICON" -nt "$DEV_ICON" ] || [ "$script" -nt "$DEV_ICON" ]; then
        mkdir -p "$(dirname "$DEV_ICON")"
        swift "$script" "$OFFICIAL_ICON" "$DEV_ICON" >&2
    fi
    echo "$DEV_ICON"
}

# The Finder icon of .papertalk files, generated from the official icon on every channel,
# and regenerated when either it or the script is newer.
document_icon() {
    local script="$ROOT/scripts/document_icon.swift"
    if [ ! -f "$DOCUMENT_ICON" ] || [ "$OFFICIAL_ICON" -nt "$DOCUMENT_ICON" ] || [ "$script" -nt "$DOCUMENT_ICON" ]; then
        mkdir -p "$(dirname "$DOCUMENT_ICON")"
        swift "$script" "$OFFICIAL_ICON" "$DOCUMENT_ICON" >&2
    fi
    echo "$DOCUMENT_ICON"
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
    local source_file="dist/Papertalk-$VERSION-source.tar.gz" icon_file document_icon_file
    icon_file="$(icon)"
    document_icon_file="$(document_icon)"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp ".build/$config/Papertalk" "$app/Contents/MacOS/Papertalk"
    cp Sources/Papertalk/macOS/Info.plist "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
    cp "$icon_file" "$app/Contents/Resources/Papertalk.icns"
    cp "$document_icon_file" "$app/Contents/Resources/PaperDocument.icns"
    plutil -replace CFBundleIconFile -string Papertalk "$app/Contents/Info.plist"
    codesign --force --sign - "$app" >/dev/null 2>&1 || true
    echo "Built $app (version $VERSION, build $BUILD_NUMBER, $CHANNEL icon)"
    if [ "${2:-}" = zip ]; then
        rm -f dist/Papertalk-*.zip dist/Papertalk-*-source.tar.gz
        ditto -c -k --keepParent "$app" "$zip_file"
        # The committed source the app was built from (uncommitted changes aren't included).
        git -C "$ROOT" archive --format=tar.gz --prefix="Papertalk-$VERSION/" -o "$CLIENT/$source_file" HEAD
        echo "Bundled $zip_file and $source_file"
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

# Build a release-optimized .app bundle, zip it into dist/Papertalk-<version>.zip and
# archive its source into dist/Papertalk-<version>-source.tar.gz.
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
    release) release ;;  # VERSION=... overrides the file for this build only; CHANNEL=stable for the official icon
    test)    test ;;
    coverage) coverage ;;
    clean)   clean ;;
    version) echo "$VERSION" ;;
    '') usage ;;
    *)   usage ;;
esac