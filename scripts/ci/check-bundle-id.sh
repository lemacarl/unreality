#!/bin/bash
# Fails if AppIdentity.bundleIdentifier (Sources/UnrealityCore/AppIdentity.swift)
# and PRODUCT_BUNDLE_IDENTIFIER in project.yml disagree, or, when --app is
# given, if the built app's Info.plist CFBundleIdentifier differs from them.
# macOS ties privacy (TCC) grants to the bundle ID, so drift is a bug.
#
# Usage: scripts/ci/check-bundle-id.sh [--app PATH/TO/Unreality.app] [REPO_ROOT]
set -euo pipefail

app=""
if [[ "${1:-}" == "--app" ]]; then
    app="$2"
    shift 2
fi
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

swift_file="$root/Sources/UnrealityCore/AppIdentity.swift"
swift_ids="$(sed -nE 's/^[[:space:]]*public static let bundleIdentifier = "([^"]*)"[[:space:]]*$/\1/p' "$swift_file")"
yml_ids="$(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$root/project.yml")"

if [[ "$(printf '%s\n' "$swift_ids" | grep -c .)" -ne 1 ]]; then
    echo "::error::Expected exactly one 'public static let bundleIdentifier = \"...\"' in AppIdentity.swift, found: '$swift_ids'"
    exit 1
fi
if [[ "$(printf '%s\n' "$yml_ids" | grep -c .)" -ne 1 ]]; then
    echo "::error::Expected exactly one PRODUCT_BUNDLE_IDENTIFIER in project.yml, found: '$yml_ids'"
    exit 1
fi
if [[ "$swift_ids" != "$yml_ids" ]]; then
    echo "::error::Bundle ID drift: AppIdentity.bundleIdentifier is '$swift_ids' but project.yml PRODUCT_BUNDLE_IDENTIFIER is '$yml_ids'"
    exit 1
fi

if [[ -n "$app" ]]; then
    built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    if [[ "$built_id" != "$swift_ids" ]]; then
        echo "::error::Bundle ID drift: built app CFBundleIdentifier is '$built_id', expected '$swift_ids'"
        exit 1
    fi
    echo "Bundle ID OK: $swift_ids (AppIdentity, project.yml, built Info.plist)."
else
    echo "Bundle ID OK: $swift_ids (AppIdentity, project.yml)."
fi
