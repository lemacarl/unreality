# 0001 — Technology stack

- Status: Accepted
- Date: 2026-10-20
- Spike: #1

## Context
Unreality needs ScreenCaptureKit, Vision OCR, AVFoundation face detection, Accessibility, idle time, Keychain, menu-bar presence and launch-at-login, with strong privacy, low resource use, CI testability and CLI-driven agent builds. Three researchers evaluated the options. Evidence is cited under Sources; points the researchers could not verify are marked *(unverified)* and were not decisive.

## Options
1. **Native Swift + SwiftUI/AppKit** (SwiftPM core + thin Xcode app shell).
2. **Tauri 2 (Electron as comparison) + Swift sidecars.**
3. **Build on Screenpipe** (and ActivityWatch as a secondary candidate).

## Scoring (1–5, weighted by priority order)
| Criterion (weight) | Native Swift | Tauri + Swift | Screenpipe/AW |
|---|---|---|---|
| macOS capability access (7) | 5 | 3 (researcher estimate, *unverified*: most OS-facing code ends up Swift/objc2 anyway) | 2 |
| Privacy / on-device (6) | 5 | 4 | 1 (Screenpipe stores raw frames/audio, telemetry on by default) |
| Resource use (5) | 5 | 3 (webview/extra processes; figures unmeasured) | 1 (5–20% CPU, 0.5–3 GB RAM per its README) |
| CI testability (4) | 4 | 3 (three toolchains) | 2 |
| Agent productivity (3) | 3 | 2 (Swift+Rust+TS, TCC attribution) | 2 |
| Maintenance / licence (2) | 4 | 3 | 1 (Screenpipe commercial licence bars distribution and competing products) |
| Packaging / notarisation (1) | 4 | 2 (nested signing unverified) | 1 |
| **Weighted total (/140)** | **127** | **86** | **42** |

Native Swift scores at least as high as both alternatives on every criterion, so the outcome does not depend on the weights.

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

## Sources
- Screenpipe licence, telemetry, resource claims, architecture: https://github.com/mediar-ai/screenpipe and https://github.com/mediar-ai/screenpipe/blob/main/LICENSE.md
- ActivityWatch (MPL-2.0, events only): https://github.com/ActivityWatch/activitywatch
- macOS 15 monthly screen-recording re-prompt: https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/ (2024 beta reporting; re-verify on current macOS)
- Tauri sidecars: https://v2.tauri.app/develop/sidecar/ ; screencapturekit Rust crate: https://docs.rs/crate/screencapturekit/8.0.1
- TCC/ad-hoc signing pitfalls: https://github.com/CapSoftware/Cap/issues/1722
- Tauri/Electron memory figures (blog-grade, unmeasured): https://www.pkgpulse.com/guides/electron-vs-tauri-2026
- Runner images and Xcode availability: https://github.com/actions/runner-images

## Revisit if
Screenpipe/ActivityWatch licensing or resource profile changes materially, `MenuBarExtra`/SwiftData mature enough to drop the AppKit/GRDB choices, or native UI work proves a bottleneck relative to web UI, or Apple restricts the needed capture APIs in a way a different runtime would avoid.
