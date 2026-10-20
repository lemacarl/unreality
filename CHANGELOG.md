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
- `SecretStore` protocol with redacting `SecretValue`, `SecretKey` and `SecretStoreError` types and an `InMemorySecretStore` fake in `UnrealityCore`; `KeychainSecretStore` (Security framework, injectable service namespace) in `UnrealityPlatform`. Contract unit tests run against the fake; an opt-in integration test (`UNREALITY_KEYCHAIN_TESTS=1`) runs against the real Keychain (#14).
- SQLite storage via GRDB.swift 7.11.1 (exact pin): `DatabaseManager` (file-backed `DatabasePool` in Application Support, in-memory `DatabaseQueue` for tests), a migration framework with an initial `events`/`sessions` schema, and `ActivityRepository` with retention hooks (`deleteEvents(endedBefore:)`, `deleteSessions(endedBefore:)`, which truncate the write-ahead log after purging), plus in-memory unit tests (#16).
- `core_no_os_imports` now allows GRDB in `UnrealityCore` (#16).
- GitHub Actions CI (`ci` check) on every PR and on `main`: pinned `macos-26` runner and Xcode 26.1.1, checksum-verified pinned XcodeGen/SwiftLint, SwiftLint `--strict`, `swift build`/`swift test`, XcodeGen + `xcodebuild` app build, SwiftPM cache; no secrets (#11).
- CI guards in `scripts/ci/`: compiler-based backstop for the `UnrealityCore` import allow-list, SwiftLint escape-hatch check, bundle-ID drift check, tool-version drift check (including the GRDB pin in `Package.swift`, `Package.resolved` and CONTRIBUTING), and a self-test proving each guard catches violations (#11).
- `swiftlint_version` pin in `.swiftlint.yml` (#11).
- `WallClock` and `Scheduler` protocols with `SystemClock`/`DispatchScheduler` and a `FakeTime` test double (#15).
- Global pause hotkey, Control-Option-Command-P by default, toggling `CaptureStateStore` via `HotkeyRegistrar` (Carbon `RegisterEventHotKey`) and `PauseHotkeyController`, with `FakeHotkeyRegistrar` (#15).
- `SettingsStore` protocol with typed `SettingKey`/`SettingValue` values, `AppSettings` (idle threshold and retention-window placeholders), an `InMemorySettingsStore` fake and an observable `SettingsModel` in `UnrealityCore`; `UserDefaultsSettingsStore` in `UnrealityPlatform`, so settings persist across launches. Unit tests cover the contract against both stores (#13).
- Settings window (SwiftUI `Settings` scene) opened from a "Settings…" button in the status popover, with General (read-only pause shortcut), Capture (idle threshold), Privacy (retention windows) and AI sections; capture, blocklist and AI content are stubs for later milestones (#13).

### Changed
- `CaptureStateStore` is now owned by an `AppModel` held by the app delegate instead of the SwiftUI `App` struct (#15).
