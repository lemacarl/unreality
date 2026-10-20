#!/bin/bash
# Self-test for the CI guards: each guard must pass on a clean copy of the
# repo and fail on an injected violation. Runs in CI so a guard that silently
# stops catching anything fails the build. Also replaces the manual probe
# files described in CONTRIBUTING.md ("Lint rules") for the SwiftLint import
# rules.
#
# Usage: scripts/ci/selftest.sh   (needs swiftlint and Xcode on PATH, and a
#                                  prior `swift build` for package modules)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
count=0

fresh() { # new clean copy of the files the guards read; cd into it
    count=$((count + 1))
    local fixture="$work/repo-$count"
    mkdir -p "$fixture"
    for item in .swiftlint.yml Package.swift Package.resolved project.yml CONTRIBUTING.md Sources Tests App scripts; do
        cp -R "$root/$item" "$fixture/"
    done
    cd "$fixture"
}

expect() { # pass|fail[:TEXT], description, command...
    # fail:TEXT also requires TEXT in the output, so a guard that fails for
    # an unrelated reason (e.g. a compiler error) does not count.
    local want="${1%%:*}" text="" what="$2" got
    [[ "$1" == *:* ]] && text="${1#*:}"
    shift 2
    if "$@" >"$work/out.log" 2>&1; then got=pass; else got=fail; fi
    if [[ "$got" == fail && -n "$text" ]] && ! grep -qF -- "$text" "$work/out.log"; then
        got="fail without '$text'"
    fi
    if [[ "$got" == "$want" ]]; then
        echo "ok   - $what ($want)"
    else
        echo "FAIL - $what: expected $want, got $got"
        sed 's/^/       /' "$work/out.log"
        failures=$((failures + 1))
    fi
}

lint() { swiftlint lint --strict --quiet --no-cache "$@"; }
# Package modules (GRDB) come from the real checkout's SwiftPM build, so the
# fixtures need no network or rebuild; run `swift build` first.
bin_path="$(cd "$root" && swift build --show-bin-path)"
scratch="$(dirname "$(dirname "$bin_path")")"
core_imports() {
    python3 scripts/ci/check-core-imports.py \
        --modules-dir "$bin_path/Modules" --checkouts-dir "$scratch/checkouts" .
}
hatches() { bash scripts/ci/check-lint-escape-hatches.sh .; }
bundle_id() { bash scripts/ci/check-bundle-id.sh .; }
versions() { bash scripts/ci/check-tool-versions.sh --files-only .; }

core="Sources/UnrealityCore"
tests="Tests/UnrealityCoreTests"

# Clean baseline: every guard passes.
fresh
expect pass "clean: swiftlint" lint
expect pass "clean: core imports" core_imports
expect pass "clean: escape hatches" hatches
expect pass "clean: bundle ID" bundle_id
expect pass "clean: tool versions" versions

# SwiftLint import rules (the regex guard).
for dir in "$core" "$tests"; do
    if [[ "$dir" == "$core" ]]; then rule=core_no_os_imports; else rule=core_tests_no_os_imports; fi
    fresh
    printf '@preconcurrency import AVFoundation\n' >"$dir/ZZProbe.swift"
    expect "fail:($rule)" "swiftlint flags @preconcurrency import in $dir" lint "$dir/ZZProbe.swift"
    fresh
    printf 'internal import AVFoundation\n' >"$dir/ZZProbe.swift"
    expect "fail:($rule)" "swiftlint flags internal import in $dir" lint "$dir/ZZProbe.swift"
    fresh
    printf 'import struct Foundation.Data\n' >"$dir/ZZProbe.swift"
    expect pass "swiftlint allows import struct Foundation.Data in $dir" lint "$dir/ZZProbe.swift"
done
# GRDB (ADR 0002) is allowed in the core but not in its tests.
fresh
printf 'import GRDB\n' >"$core/ZZProbe.swift"
expect pass "swiftlint allows import GRDB in $core" lint "$core/ZZProbe.swift"
fresh
printf 'import GRDB\n' >"$tests/ZZProbe.swift"
expect "fail:(core_tests_no_os_imports)" "swiftlint flags import GRDB in $tests" lint "$tests/ZZProbe.swift"

# Compiler backstop: catches what the regex cannot.
fresh
printf 'import Foundation\nimport /* c */ AppKit\n' >"$core/ZZProbe.swift"
expect "fail:(debug) imports modules outside the allow-list: AppKit" \
    "core imports: comment-hidden AppKit import" core_imports
fresh
printf 'import Foundation\nimport IOKit\n' >"$core/ZZProbe.swift"
expect "fail:(debug) imports modules outside the allow-list: IOKit" \
    "core imports: IOKit (inside Foundation's loaded closure)" core_imports
fresh
printf 'import Foundation\nimport Carbon\n' >"$core/ZZProbe.swift"
expect "fail:(release) imports modules outside the allow-list: Carbon" \
    "core imports: Clang-only module" core_imports
fresh
printf '#if DEBUG\n@_implementationOnly import os\n#endif\n' >"$core/ZZProbe.swift"
expect "fail:(debug) imports modules outside the allow-list: os" \
    "core imports: debug-only import" core_imports
fresh
printf 'import struct Foundation.Data\nimport RegexBuilder\n' >"$core/ZZProbe.swift"
expect pass "core imports: allow-listed scoped import" core_imports
fresh
printf 'import GRDB\n' >"$core/ZZProbe.swift"
expect pass "core imports: allow-listed package module (GRDB)" core_imports
fresh
printf 'import GRDB\nimport SQLite3\n' >"$core/ZZProbe.swift"
expect "fail:(debug) imports modules outside the allow-list: SQLite3" \
    "core imports: raw SQLite3 next to GRDB" core_imports
fresh
printf 'import GRDBSQLite\n' >"$core/ZZProbe.swift"
expect "fail:(debug) imports modules outside the allow-list: GRDBSQLite" \
    "core imports: GRDB's internal shim module" core_imports

# Escape hatches.
fresh
printf 'disabled_rules:\n  - custom_rules\n' >"$core/.swiftlint.yml"
expect "fail:file=$core/.swiftlint.yml::Nested" "escape hatches: nested config under the core" hatches
fresh
ln -s "$work/elsewhere.yml" "$core/.swiftlint.yml"
expect "fail:file=$core/.swiftlint.yml::Nested" "escape hatches: symlinked nested config" hatches
fresh
printf 'only_rules: []\n' >"Sources/.swiftlint.yaml"
expect "fail:file=Sources/.swiftlint.yaml::Nested" "escape hatches: nested config above the core" hatches
fresh
printf '// swiftlint:disable:next core_no_os_imports\nimport AppKit\n' >"$core/ZZProbe.swift"
expect "fail:file=$core/ZZProbe.swift,line=1::swiftlint:disable of an UnrealityCore" \
    "escape hatches: disable:next core_no_os_imports" hatches
fresh
printf '// swiftlint:disable core_tests_no_os_imports\n' >"$tests/ZZProbe.swift"
expect "fail:file=$tests/ZZProbe.swift,line=1::swiftlint:disable of an UnrealityCore" \
    "escape hatches: disable core_tests_no_os_imports" hatches
fresh
printf '// swiftlint:disable all\n' >"$core/ZZProbe.swift"
expect "fail:file=$core/ZZProbe.swift,line=1::swiftlint:disable all/custom_rules" \
    "escape hatches: disable all in the core" hatches
fresh
printf 'import Foundation // swiftlint:disable:this custom_rules\n' >"$tests/ZZProbe.swift"
expect "fail:file=$tests/ZZProbe.swift,line=1::swiftlint:disable all/custom_rules" \
    "escape hatches: disable custom_rules in core tests" hatches
fresh
printf '// swiftlint:disable:next force_unwrapping\nlet value = Int("1")!\n' >"$core/ZZProbe.swift"
expect pass "escape hatches: unrelated rule disable allowed" hatches

# Bundle ID drift.
fresh
sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER: com.lemacarl.unreality/PRODUCT_BUNDLE_IDENTIFIER: com.lemacarl.other/' project.yml
expect "fail:Bundle ID drift" "bundle ID: project.yml drift" bundle_id
fresh
sed -i '' 's/bundleIdentifier = "com.lemacarl.unreality"/bundleIdentifier = "com.lemacarl.other"/' "$core/AppIdentity.swift"
expect "fail:Bundle ID drift" "bundle ID: AppIdentity drift" bundle_id

# Tool version drift.
fresh
sed -i '' 's/| SwiftLint | [0-9.]* |/| SwiftLint | 0.0.1 |/' CONTRIBUTING.md
expect "fail:CONTRIBUTING.md SwiftLint pin" "tool versions: CONTRIBUTING drift" versions
fresh
sed -i '' 's/^swiftlint_version: .*/swiftlint_version: 0.0.1/' .swiftlint.yml
expect "fail:.swiftlint.yml swiftlint_version" "tool versions: .swiftlint.yml drift" versions
fresh
sed -i '' 's/minimumXcodeGenVersion: .*/minimumXcodeGenVersion: "99.0.0"/' project.yml
expect "fail:is newer than the pinned XcodeGen" "tool versions: minimumXcodeGenVersion above the pin" versions
fresh
sed -i '' 's/| GRDB.swift (runtime) | [0-9.]*/| GRDB.swift (runtime) | 0.0.1/' CONTRIBUTING.md
expect "fail:GRDB pin drift" "tool versions: GRDB CONTRIBUTING drift" versions
fresh
sed -i '' 's/"version" : "[0-9.]*"/"version" : "0.0.1"/' Package.resolved
expect "fail:GRDB pin drift" "tool versions: GRDB Package.resolved drift" versions
fresh
sed -i '' 's/GRDB.swift.git", exact: "\([0-9.]*\)"/GRDB.swift.git", from: "\1"/' Package.swift
expect "fail:must pin GRDB with exact:" "tool versions: GRDB not exact-pinned" versions

if [[ "$failures" -gt 0 ]]; then
    echo "::error::CI guard self-test: $failures case(s) failed."
    exit 1
fi
echo "CI guard self-test passed."
