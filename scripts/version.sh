#!/usr/bin/env bash
# Papertalk versioning. The single source of truth is the VERSION file at the
# repo root (semantic versioning, MAJOR.MINOR.PATCH). The app build stamps it
# into Info.plist; the release workflow publishes a tag named v<VERSION>.
#
#   scripts/version.sh                  print the current version
#   scripts/version.sh bump patch       0.0.1 -> 0.0.2   (also: minor, major)
#   scripts/version.sh set 1.2.3        set an explicit version
#   scripts/version.sh check-tag v1.2.3 fail unless the tag matches VERSION
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/VERSION"
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

current() {
    local v
    v="$(tr -d '[:space:]' < "$FILE")"
    [[ "$v" =~ $SEMVER ]] || { echo "VERSION is not MAJOR.MINOR.PATCH: '$v'" >&2; exit 1; }
    echo "$v"
}

write() {
    [[ "$1" =~ $SEMVER ]] || { echo "Not a MAJOR.MINOR.PATCH version: '$1'" >&2; exit 1; }
    echo "$1" > "$FILE"
    echo "Version $(current)"
    echo "Next: commit VERSION (via a pull request), then on main run: make -C client tag && git push origin v$1"
}

case "${1:-show}" in
    show)
        current
        ;;
    bump)
        IFS=. read -r major minor patch <<< "$(current)"
        case "${2:-}" in
            patch) patch=$((patch + 1)) ;;
            minor) minor=$((minor + 1)); patch=0 ;;
            major) major=$((major + 1)); minor=0; patch=0 ;;
            *) echo "usage: $0 bump patch|minor|major" >&2; exit 2 ;;
        esac
        write "$major.$minor.$patch"
        ;;
    set)
        write "${2:-}"
        ;;
    check-tag)
        tag="${2:-}"
        if [[ "$tag" != "v$(current)" ]]; then
            echo "Tag '$tag' does not match VERSION $(current) (expected v$(current))." >&2
            exit 1
        fi
        echo "Tag $tag matches VERSION."
        ;;
    *)
        echo "usage: $0 [show | bump patch|minor|major | set X.Y.Z | check-tag vX.Y.Z]" >&2
        exit 2
        ;;
esac
