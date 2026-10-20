# 0002 — Initial third-party dependencies and tools

- Status: Accepted
- Date: 2026-10-20

## Decision
| Item | Kind | Licence | Why it beats a native API |
|---|---|---|---|
| GRDB.swift | runtime | MIT | Migrations, WAL, in-memory DBs for tests, observation; raw sqlite3 is boilerplate-heavy, SwiftData is poor for CLI/agent work and explicit migrations. |
| XcodeGen | build tool | MIT | Generates the Xcode project from `project.yml`; avoids hand-edited `.xcodeproj` merge conflicts. Not shipped. |
| SwiftLint | lint tool | MIT | Standard Swift linter; CLI-runnable in CI. Not shipped. |

No other dependencies are approved. Hotkeys use Carbon directly; Sparkle (updates) needs its own ADR in M7. Each needs maintenance health re-checked when the scaffold is built (pin versions).

## Revisit if
A dependency becomes unmaintained or a native API closes the gap.
