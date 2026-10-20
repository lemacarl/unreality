# 0002 — Initial third-party dependencies and tools

- Status: Accepted
- Date: 2026-10-20

## Context
ADR 0001 chose native Swift; the guardrails require an ADR for each dependency. Rejected alternatives: raw sqlite3 and SQLite.swift (more boilerplate), SwiftData (poor CLI/agent ergonomics, implicit migrations), hand-maintained `.xcodeproj` or Tuist (heavier).

## Decision
| Item | Kind | Licence | Rationale |
|---|---|---|---|
| GRDB.swift | runtime | MIT | Migrations, WAL, in-memory DBs for tests, observation; raw sqlite3 is boilerplate-heavy, SwiftData is poor for CLI/agent work and explicit migrations. |
| XcodeGen | build tool | MIT | Generates the Xcode project from `project.yml`; avoids hand-edited `.xcodeproj` merge conflicts. Not shipped. |
| SwiftLint | lint tool | MIT | Standard Swift linter; CLI-runnable in CI. Not shipped. |

No other dependencies are approved. Hotkeys use Carbon directly; Sparkle (updates) needs its own ADR in M7. Versions are pinned in the scaffold issue (#10), which also re-checks maintenance health.

_Note (#10):_ XcodeGen and SwiftLint are pinned in CONTRIBUTING.md (Tool versions). The scaffold needs no runtime dependency, so GRDB is not added yet; its version pin and health re-check are deferred to the storage issue (#16).

_Note (#16):_ GRDB.swift is pinned at exactly 7.11.1 (health re-check in CONTRIBUTING.md, Tool versions) and is used only by `UnrealityCore` (not enforced outside it yet; the CI backstop in #11 could).

## Consequences
One runtime dependency (GRDB) enters the app; the two tools are build-time only.

## Revisit if
A dependency becomes unmaintained or a native API closes the gap.
