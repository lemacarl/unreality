# Changelog
All notable changes follow [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]
### Added
- Documentation skeleton, ADRs 0001–0002, issue/PR templates, agent role configs.
- SwiftPM package with `UnrealityCore` and `UnrealityPlatform` libraries and Swift Testing targets (Swift 6 language mode) (#10).
- XcodeGen `project.yml` for a menu-bar-only app shell (macOS 14, `LSUIElement`, bundle ID `com.lemacarl.unreality`) (#10).
- `.swiftlint.yml`, including allow-list rules that limit `UnrealityCore` and its tests to Foundation-level imports (#10).
- `Config/Signing.xcconfig` (ad-hoc signing by default) with an optional, gitignored `Config/Local.xcconfig` for a developer's own team (#10).
- README build/run instructions and required permissions; pinned tool versions in CONTRIBUTING (#10).
- `CaptureStateStore` in `UnrealityCore`: observable running/paused capture state with `pause()`, `resume()` and `toggle()`, plus unit tests (#12).
- Menu-bar status item whose icon shows capture state (`eye` running, `eye.slash` paused) and a popover with the state, a Pause/Resume control and Quit (#12).
