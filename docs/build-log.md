# Build log

## 2026-10-20 — Phase 0 bootstrap
- Labels and milestones M1–M7 created; repo was empty, so one bootstrap commit (README, .gitignore) went directly to `main` (unavoidable on an empty repo; everything since goes via PR).
- Stack spike (#1): three researchers evaluated native Swift, Tauri/Electron + Swift sidecars, and Screenpipe/ActivityWatch. Decision: native Swift (ADR 0001); dependencies ADR 0002.
- Next: merge docs skeleton, create epics/issues, scaffold + CI.

## 2026-10-20 to 2026-10-22 — Cycle 1: M1 foundations and the start of M2
**Merged** (all squash-merged after independent review; privacy-labelled PRs also had a privacy/security review):
- #2 docs, ADRs 0001-0002 (native Swift; GRDB, XcodeGen, SwiftLint), templates, agent roles
- #51 SwiftPM core/platform packages and XcodeGen app shell (#10)
- #52 menu-bar presence and capture state (#12)
- #53 Keychain secret store (#14)
- #55 CI: build, tests, SwiftLint and guard scripts, including a compiler-based backstop for the core import rule (#11)
- #57 clock/scheduler abstractions and the global pause hotkey (#15)
- #58 SQLite storage with GRDB, migrations and WAL-truncating retention hooks (#16)
- #63 settings window and settings store (#13)
- #64 activity source: frontmost app and window title via Accessibility (#17)
- #65 privacy filter, drop-before-storage and URL redaction (#20)
- #69 launch at login (#56)
- #70 session aggregation with anonymous exclusion boundaries (#21)

**In review:** #71 browser URL capture with site exclusion (#19).

**What review caught** (none of these would have been found by CI): `blob:`/`view-source:` and percent-encoded hosts bypassing the site exclusion, deleted data lingering in the SQLite WAL, a dangling Apple Event pointer, a midnight split that is wrong in time zones where DST starts at midnight, idle time that could be stored inside paused time, and several unverified claims in docs.

**Process notes:** branch protection on `main` is enabled by the PM (required check `ci`, 0 required approvals because reviewers share the owner's GitHub account; see #50). Rate limits interrupted several agents; work resumed from the saved worktrees or branches. Several PRs exceeded the ~400-line guideline; reviewers judged each cohesive.

**Blocked / waiting on the owner:** licence choice and a second reviewer account (#50); M1 manual test session (to be filed); Apple Developer and Anthropic credentials later (M5/M7).

**Next:** merge #71; idle detection (#18); timeline view (#22); wire the pipeline into the app; M3 screen capture. Open follow-ups: #54, #59, #60, #61, #62, #66, #67, #68, #72.
