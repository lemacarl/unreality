# 0001 — Technology stack

- Status: Accepted
- Date: 2026-10-20
- Spike: #1

## Context
Unreality needs ScreenCaptureKit, Vision OCR, AVFoundation face detection, Accessibility, idle time, Keychain, menu-bar presence and launch-at-login, with strong privacy, low resource use, CI testability and CLI-driven agent builds. Three researchers evaluated the options (evidence: vendor docs, issue trackers, repo licences; some points were flagged unverified by the researchers).

## Options
1. **Native Swift + SwiftUI/AppKit** (SwiftPM core + thin Xcode app shell).
2. **Tauri 2 (Electron as comparison) + Swift sidecars.**
3. **Build on Screenpipe** (and ActivityWatch as a secondary candidate).

## Scoring (1–5, weighted by priority order)
| Criterion (weight) | Native Swift | Tauri + Swift | Screenpipe/AW |
|---|---|---|---|
| macOS capability access (7) | 5 | 3 (≈60% of risky code is Swift/objc2 anyway) | 2 |
| Privacy / on-device (6) | 5 | 4 | 1 (Screenpipe stores raw frames/audio, telemetry on by default) |
| Resource use (5) | 5 | 3 | 1 (5–20% CPU, 0.5–3 GB RAM reported) |
| CI testability (4) | 4 | 3 (three toolchains) | 2 |
| Agent productivity (3) | 3 | 2 (Swift+Rust+TS, TCC attribution) | 2 |
| Maintenance / licence (2) | 4 | 3 | 1 (Screenpipe commercial licence bars distribution and competing products) |
| Packaging / notarisation (1) | 4 | 2 (nested signing unverified) | 1 |
| **Weighted total (/140)** | **~129** | **~84** | **~51** |

## Decision
**Native Swift.** Layout:
- `UnrealityCore` (SwiftPM library): pure logic and domain types, no AppKit/ScreenCaptureKit/AVFoundation imports; all system integrations as protocols (`ActivitySource`, `ScreenCapturer`, `OCRService`, `FaceDetector`, `KeychainStore`, `Clock`, `HotkeyRegistrar`, `LoginItemService`, `AIClient`) with fakes.
- `UnrealityPlatform` (SwiftPM library): real implementations of those protocols.
- App shell: SwiftUI app generated from `project.yml` with XcodeGen so agents never hand-edit `.xcodeproj`.
- Deployment target macOS 14 (SCScreenshotManager). Swift 6 toolchain; language mode decided in the scaffold issue.
- Storage: SQLite via GRDB (see ADR 0002). Menu bar via `NSStatusItem`/`NSPopover` if `MenuBarExtra` proves limiting. Hotkey via Carbon `RegisterEventHotKey`. Launch at login via `SMAppService`.
- CI: GitHub Actions macOS runner, `swift test` on the core, `xcodebuild` build of the app, SwiftLint.

## Consequences
- Capture, camera and Accessibility layers cannot be verified in CI; they stay thin, are covered by fakes, and verified in batched manual test sessions.
- macOS 15+ re-prompts for screen recording roughly monthly; the app needs a graceful re-permission flow and a visible "capture paused" state (tracked for M3/M6).
- Dev builds need a stable signing identity to keep TCC grants; documented in CONTRIBUTING.
- Notarisation needs a paid Apple Developer account (escalated to the owner).

## Revisit if
Native UI work proves a bottleneck relative to web UI, or Apple restricts the needed capture APIs in a way a different runtime would avoid.
