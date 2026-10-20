#!/bin/bash
# Fails if the pinned tool versions drift. Compares scripts/ci/tool-versions.env
# with CONTRIBUTING.md ("Tool versions" table), .swiftlint.yml
# (swiftlint_version) and project.yml (minimumXcodeGenVersion must not exceed
# the pin), and, unless --files-only is given, with the installed Xcode,
# Swift, XcodeGen and SwiftLint.
#
# Usage: scripts/ci/check-tool-versions.sh [--files-only] [REPO_ROOT]
set -euo pipefail

files_only=0
if [[ "${1:-}" == "--files-only" ]]; then
    files_only=1
    shift
fi
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/ci/tool-versions.env
source "$root/scripts/ci/tool-versions.env"

failures=0
fail() {
    echo "::error::$1"
    failures=$((failures + 1))
}
expect_line() { # file fixed-string description
    if ! grep -qF -- "$2" "$1"; then
        fail "$3: expected '$2' in ${1#"$root"/}"
    fi
}

contributing="$root/CONTRIBUTING.md"
expect_line "$contributing" "| Xcode / Swift | $XCODE_VERSION / $SWIFT_VERSION |" "CONTRIBUTING.md Xcode/Swift pin"
expect_line "$contributing" "| XcodeGen | $XCODEGEN_VERSION |" "CONTRIBUTING.md XcodeGen pin"
expect_line "$contributing" "| SwiftLint | $SWIFTLINT_VERSION |" "CONTRIBUTING.md SwiftLint pin"

lint_version="$(sed -nE 's/^swiftlint_version:[[:space:]]*"?([0-9.]+)"?[[:space:]]*$/\1/p' "$root/.swiftlint.yml")"
if [[ "$lint_version" != "$SWIFTLINT_VERSION" ]]; then
    fail ".swiftlint.yml swiftlint_version is '$lint_version', pinned $SWIFTLINT_VERSION"
fi

min_xcodegen="$(sed -nE 's/^[[:space:]]*minimumXcodeGenVersion:[[:space:]]*"?([0-9.]+)"?[[:space:]]*$/\1/p' "$root/project.yml")"
if [[ -z "$min_xcodegen" ]]; then
    fail "project.yml has no minimumXcodeGenVersion"
elif [[ "$(printf '%s\n%s\n' "$min_xcodegen" "$XCODEGEN_VERSION" | sort -V | tail -n 1)" != "$XCODEGEN_VERSION" ]]; then
    fail "project.yml minimumXcodeGenVersion $min_xcodegen is newer than the pinned XcodeGen $XCODEGEN_VERSION"
fi

# Runtime dependency GRDB (ADR 0002): the CONTRIBUTING row, the `exact:` pin
# in Package.swift and the Package.resolved lock must agree.
if grep -q 'GRDB.swift.git' "$root/Package.swift"; then
    grdb_package="$(sed -nE 's|.*\.package\(url: "https://github.com/groue/GRDB.swift.git", exact: "([0-9.]+)"\).*|\1|p' "$root/Package.swift")"
    grdb_doc="$(sed -nE 's/^\| GRDB\.swift \(runtime\) \| ([0-9.]+)[ |].*/\1/p' "$contributing")"
    grdb_resolved="$(python3 -c 'import json,sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next((p["state"].get("version", "") for p in pins if p["identity"] == "grdb.swift"), ""))' "$root/Package.resolved" 2>/dev/null || true)"
    if [[ -z "$grdb_package" ]]; then
        fail "Package.swift must pin GRDB with exact: \"x.y.z\""
    elif [[ "$grdb_doc" != "$grdb_package" || "$grdb_resolved" != "$grdb_package" ]]; then
        fail "GRDB pin drift: Package.swift '$grdb_package', Package.resolved '$grdb_resolved', CONTRIBUTING.md '$grdb_doc'"
    fi
fi

if [[ "$files_only" -eq 0 ]]; then
    installed_xcode="$(xcodebuild -version | sed -nE '1s/^Xcode ([0-9.]+)$/\1/p')"
    [[ "$installed_xcode" == "$XCODE_VERSION" ]] ||
        fail "Xcode is '$installed_xcode', pinned $XCODE_VERSION"
    installed_swift="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -n 1)"
    [[ "$installed_swift" == "$SWIFT_VERSION" ]] ||
        fail "Swift is '$installed_swift', pinned $SWIFT_VERSION"
    installed_xcodegen="$(xcodegen --version | sed -nE 's/^Version: ([0-9.]+)$/\1/p')"
    [[ "$installed_xcodegen" == "$XCODEGEN_VERSION" ]] ||
        fail "XcodeGen is '$installed_xcodegen', pinned $XCODEGEN_VERSION"
    installed_swiftlint="$(swiftlint version)"
    [[ "$installed_swiftlint" == "$SWIFTLINT_VERSION" ]] ||
        fail "SwiftLint is '$installed_swiftlint', pinned $SWIFTLINT_VERSION"
fi

if [[ "$failures" -gt 0 ]]; then
    echo "Tool version check failed ($failures problem(s)); see scripts/ci/tool-versions.env." >&2
    exit 1
fi
echo "Tool versions OK: Xcode $XCODE_VERSION, Swift $SWIFT_VERSION, XcodeGen $XCODEGEN_VERSION, SwiftLint $SWIFTLINT_VERSION."
