#!/bin/bash
# Installs the pinned XcodeGen and SwiftLint release binaries into DEST
# (default: .build/ci-tools) after verifying their SHA-256 digests, then
# prints the directories to put on PATH, one per line (the format
# $GITHUB_PATH expects). Versions and digests come from
# scripts/ci/tool-versions.env.
#
# Usage: scripts/ci/install-tools.sh [DEST]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/ci/tool-versions.env
source "$root/scripts/ci/tool-versions.env"

dest="${1:-$root/.build/ci-tools}"
mkdir -p "$dest/downloads"

fetch() { # url sha256 file
    curl --fail --silent --show-error --location --retry 3 --output "$3" "$1"
    echo "$2  $3" | shasum -a 256 -c - >&2
}

xcodegen_zip="$dest/downloads/xcodegen-$XCODEGEN_VERSION.zip"
fetch "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    "$XCODEGEN_SHA256" "$xcodegen_zip"
rm -rf "$dest/xcodegen"
unzip -q -o "$xcodegen_zip" -d "$dest"
# The archive unpacks to xcodegen/bin/xcodegen plus xcodegen/share. XcodeGen
# finds its setting presets relative to the unresolved executable path, so a
# symlink elsewhere would silently generate a project without base settings:
# put xcodegen/bin itself on PATH.

swiftlint_zip="$dest/downloads/swiftlint-$SWIFTLINT_VERSION.zip"
fetch "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" \
    "$SWIFTLINT_SHA256" "$swiftlint_zip"
rm -rf "$dest/swiftlint"
unzip -q -o "$swiftlint_zip" -d "$dest/swiftlint"

echo "$dest/xcodegen/bin"
echo "$dest/swiftlint"
