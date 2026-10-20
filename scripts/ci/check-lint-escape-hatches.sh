#!/bin/bash
# Fails on SwiftLint escape hatches that could switch off the UnrealityCore
# import allow-list (core_no_os_imports / core_tests_no_os_imports):
#   - any nested SwiftLint config (.swiftlint.yml/.yaml other than the root
#     one), since a child config can disable or narrow rules for its folder;
#   - a `swiftlint:disable` directive (including :next/:this/:previous)
#     naming either rule in any Swift file;
#   - in Sources/UnrealityCore and Tests/UnrealityCoreTests, a disable of
#     `all` or `custom_rules`, which would switch the rules off too.
#
# Usage: scripts/ci/check-lint-escape-hatches.sh [REPO_ROOT]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$root"

failures=0

# Prune build output, VCS metadata and generated projects; everything else
# in the checkout counts.
nested_configs="$(find . \
    \( -path ./.git -o -path ./.build -o -path ./DerivedData -o -path ./.claude/worktrees -o -name '*.xcodeproj' \) -prune -o \
    \( -type f -o -type l \) \( -iname '.swiftlint.yml' -o -iname '.swiftlint.yaml' \) ! -path ./.swiftlint.yml -print)"
if [[ -n "$nested_configs" ]]; then
    while IFS= read -r path; do
        echo "::error file=${path#./}::Nested SwiftLint config is not allowed (it can disable the UnrealityCore import rules); keep all configuration in the root .swiftlint.yml."
    done <<<"$nested_configs"
    failures=$((failures + 1))
fi

swift_dirs=()
for dir in Sources Tests App; do
    [[ -d "$dir" ]] && swift_dirs+=("$dir")
done

# BSD grep: no \b, and ^ inside a mid-pattern group never matches, so the
# leading boundary is "start of the rule list or a non-identifier char".
b='(.*[^[:alnum:]_])?'
e='([^[:alnum:]_]|$)'
directive='swiftlint:disable(:next|:this|:previous)?[[:space:]]'

report() { # grep output, message
    [[ -z "$1" ]] && return 0
    while IFS= read -r hit; do
        file="${hit%%:*}"
        rest="${hit#*:}"
        line="${rest%%:*}"
        echo "::error file=$file,line=$line::$2"
    done <<<"$1"
    failures=$((failures + 1))
}

if [[ ${#swift_dirs[@]} -gt 0 ]]; then
    hits="$(grep -rnEi --include='*.swift' "${directive}${b}(core_no_os_imports|core_tests_no_os_imports)${e}" "${swift_dirs[@]}" || true)"
    report "$hits" "swiftlint:disable of an UnrealityCore import rule is not allowed."
fi

core_dirs=()
for dir in Sources/UnrealityCore Tests/UnrealityCoreTests; do
    [[ -d "$dir" ]] && core_dirs+=("$dir")
done
if [[ ${#core_dirs[@]} -gt 0 ]]; then
    hits="$(grep -rnEi --include='*.swift' "${directive}${b}(all|custom_rules)${e}" "${core_dirs[@]}" || true)"
    report "$hits" "swiftlint:disable all/custom_rules is not allowed in UnrealityCore or its tests (it disables the import rules)."
fi

if [[ "$failures" -gt 0 ]]; then
    echo "SwiftLint escape-hatch check failed." >&2
    exit 1
fi
echo "SwiftLint escape hatches: none found."
