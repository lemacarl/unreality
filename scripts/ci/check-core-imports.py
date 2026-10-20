#!/usr/bin/env python3
"""Compiler-based backstop for the UnrealityCore import allow-list.

The SwiftLint rule `core_no_os_imports` is a regex and can be fooled (for
example by `import /* c */ AppKit`). This check asks the Swift compiler
instead, so it sees exactly what the build sees:

1. Direct imports: `swiftc -scan-dependencies` over Sources/UnrealityCore
   lists the module's direct dependencies (Swift and Clang modules, after
   `#if` evaluation, comments ignored). Every one must also be a direct
   dependency of a probe file that imports only the allow-listed modules
   (so the compiler's implicit imports such as Swift and _Concurrency are
   accepted without hard-coding them).
2. Loaded modules: the `-emit-loaded-module-trace` of the core must be a
   subset of the probe's trace.

Both run for the debug (-DDEBUG -Onone) and release (-O) compilation
conditions SwiftPM uses. The allow-list is read from the
`core_no_os_imports` rule in .swiftlint.yml, so there is one list.

Package dependencies on the allow-list (GRDB) are resolved from the
modules SwiftPM built, so run `swift build` first. The module directory is
`$(swift build --show-bin-path)/Modules` unless --modules-dir is given.
Clang module maps of package dependencies (GRDB's GRDBSQLite shim) are
taken from the checkouts SwiftPM resolved next to that bin path.

Usage: python3 scripts/ci/check-core-imports.py [--modules-dir DIR] [REPO_ROOT]
"""

import json
import os
import platform
import re
import subprocess
import sys
import tempfile

RULE = "core_no_os_imports"
MODULE = "UnrealityCore"
PROBE = "UnrealityCoreAllowListProbe"
# SwiftPM passes -package-name (the root package identity) so `package`
# access level declarations type-check; any fixed value works here because
# all core files are compiled together.
PACKAGE_NAME = "unreality"
# Hard-coded mirror of the compilation conditions SwiftPM uses. If
# Package.swift gives UnrealityCore swiftSettings (.define, unsafeFlags,
# enableUpcomingFeature, ...), mirror them here too, or `#if` blocks guarded
# by them are not checked.
CONFIGS = {
    "debug": ["-Onone", "-DSWIFT_PACKAGE", "-DDEBUG"],
    "release": ["-O", "-DSWIFT_PACKAGE"],
}


def error(message):
    print(f"::error::{message}")


def allow_list(root):
    """Module names from the negative lookahead of core_no_os_imports."""
    with open(os.path.join(root, ".swiftlint.yml"), encoding="utf-8") as handle:
        text = handle.read()
    block = re.search(
        r"^  " + RULE + r":\n((?:    .*\n|\s*\n)+)", text, re.MULTILINE
    )
    if not block:
        raise SystemExit(f"::error::Rule {RULE} not found in .swiftlint.yml")
    lookahead = re.search(r"\(\?!\(\?:([A-Za-z0-9_|]+)\)", block.group(1))
    if not lookahead:
        raise SystemExit(f"::error::Could not read the allow-list of {RULE}")
    return lookahead.group(1).split("|")


def deployment_target(root):
    with open(os.path.join(root, "Package.swift"), encoding="utf-8") as handle:
        match = re.search(r"\.macOS\(\.v(\d+)(?:_(\d+))?\)", handle.read())
    if not match:
        raise SystemExit("::error::No .macOS(.vN) platform in Package.swift")
    return f"{match.group(1)}.{match.group(2) or 0}"


def swiftc(args):
    result = subprocess.run(
        ["xcrun", "swiftc", *args], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"::error::swiftc failed: {' '.join(args[:3])} ... "
                         "(package modules such as GRDB need `swift build` first)")


def direct_dependencies(base, module, sources, out):
    swiftc(["-scan-dependencies", "-whole-module-optimization", "-module-name", module,
            *base, *sources, "-o", out])
    with open(out, encoding="utf-8") as handle:
        graph = json.load(handle)
    modules = graph["modules"]
    for index in range(0, len(modules), 2):
        if modules[index].get("swift") == module:
            deps = modules[index + 1].get("directDependencies", [])
            return {name for dep in deps for name in dep.values()}
    raise SystemExit(f"::error::{module} missing from the dependency scan")


def loaded_modules(base, module, sources, out):
    swiftc(
        [
            "-typecheck",
            "-parse-as-library",
            "-whole-module-optimization",
            "-module-name",
            module,
            *base,
            *sources,
            "-emit-loaded-module-trace",
            "-emit-loaded-module-trace-path",
            out,
        ]
    )
    with open(out, encoding="utf-8") as handle:
        trace = json.load(handle)
    names = {entry["name"] for entry in trace.get("swiftmodulesDetailedInfo", [])}
    if not names:
        names = {
            os.path.basename(path).split(".")[0] for path in trace["swiftmodules"]
        }
    return names


def package_search_flags(root, modules_dir, checkouts_dir):
    """-I for SwiftPM's built modules, -fmodule-map-file for dependency shims."""
    if modules_dir is None or checkouts_dir is None:
        bin_path = subprocess.run(
            ["swift", "build", "--show-bin-path"],
            cwd=root, capture_output=True, text=True, check=True,
        ).stdout.strip()
        modules_dir = modules_dir or os.path.join(bin_path, "Modules")
        scratch = os.path.dirname(os.path.dirname(bin_path))
        checkouts_dir = checkouts_dir or os.path.join(scratch, "checkouts")
    flags = []
    if os.path.isdir(modules_dir):
        flags += ["-I", modules_dir]
    if os.path.isdir(checkouts_dir):
        for directory, _, names in sorted(os.walk(checkouts_dir)):
            if "module.modulemap" in names and f"{os.sep}Sources{os.sep}" in directory:
                flags += ["-Xcc", "-fmodule-map-file=" + os.path.join(directory, "module.modulemap")]
    return flags, modules_dir


def main():
    args = sys.argv[1:]
    modules_dir = checkouts_dir = None
    while args and args[0] in ("--modules-dir", "--checkouts-dir"):
        if len(args) < 2:
            raise SystemExit(f"::error::{args[0]} needs a directory")
        if args[0] == "--modules-dir":
            modules_dir = os.path.abspath(args[1])
        else:
            checkouts_dir = os.path.abspath(args[1])
        args = args[2:]
    root = os.path.abspath(args[0] if args else os.path.join(
        os.path.dirname(__file__), "..", ".."))
    core_dir = os.path.join(root, "Sources", MODULE)
    sources = sorted(
        os.path.join(directory, name)
        for directory, _, names in os.walk(core_dir)
        for name in names
        if name.endswith(".swift")
    )
    if not sources:
        raise SystemExit(f"::error::No Swift sources under {core_dir}")

    allowed = allow_list(root)
    sdk = subprocess.run(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    target = f"{platform.machine()}-apple-macos{deployment_target(root)}"
    search, modules_dir = package_search_flags(root, modules_dir, checkouts_dir)
    print(f"Allow-list ({RULE}): {', '.join(allowed)}; target {target}; "
          f"package modules from {modules_dir}")

    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, "Probe.swift")
        with open(probe, "w", encoding="utf-8") as handle:
            handle.writelines(f"import {name}\n" for name in allowed)

        for config, flags in CONFIGS.items():
            base = ["-sdk", sdk, "-target", target, "-swift-version", "6",
                    "-package-name", PACKAGE_NAME, *search, *flags]
            out = os.path.join(tmp, config)

            allowed_direct = direct_dependencies(base, PROBE, [probe], out + "-probe.json")
            core_direct = direct_dependencies(base, MODULE, sources, out + "-core.json")
            extra = sorted(core_direct - allowed_direct - {MODULE})
            if extra:
                failures += 1
                error(f"{MODULE} ({config}) imports modules outside the allow-list: "
                      f"{', '.join(extra)}. Put OS integrations behind a protocol "
                      "in UnrealityPlatform (ADR 0001).")

            allowed_loaded = loaded_modules(base, PROBE, [probe], out + "-probe.trace.json")
            core_loaded = loaded_modules(base, MODULE, sources, out + "-core.trace.json")
            extra = sorted(core_loaded - allowed_loaded - {MODULE})
            if extra:
                failures += 1
                error(f"{MODULE} ({config}) loads modules outside the allow-list's "
                      f"closure: {', '.join(extra)}.")

            print(f"{config}: direct imports {sorted(core_direct)}; "
                  f"{len(core_loaded)} loaded Swift modules")

    if failures:
        sys.exit(1)
    print(f"{MODULE} imports OK.")


if __name__ == "__main__":
    main()
