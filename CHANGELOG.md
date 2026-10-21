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
- `ActivitySource` protocol and `ActivitySample` / `FrontmostApp` types with a `FakeActivitySource`; `WorkspaceActivitySource` reads the frontmost app (NSWorkspace activation notifications) and its focused window title (Accessibility API, `AXObserver`; no polling) (#17).
- `AccessibilityTrust` protocol with `SystemAccessibilityTrust` (`AXIsProcessTrusted`; prompts only on explicit request) and `FakeAccessibilityTrust`; without Accessibility permission activity degrades to app-only samples (#17).
- `ActivityCoordinator`: stops the activity source while capture is paused, publishes Accessibility trust state (restarting the source when trust is granted), strips titles without trust, for processes without a bundle ID and for Unreality's own windows, and requires an `ActivitySampleFilter` (the seam for the privacy filter, #20) (#17).
- `CaptureStateStore.onChange(_:)` for synchronous, cancellable state-change handlers (#17).
- Privacy filter in `UnrealityCore` (#20): `PrivacyFilter`, the real `ActivitySampleFilter` for `ActivityCoordinator`, never allows the window titles of excluded apps, or of apps without a bundle ID, to be read. It drops excluded apps' samples (also app-only ones) and builds `FilteredEvent`s with the user's current rules; `PrivacyRules` is its pure, `Sendable` logic. Building an event drops excluded sites (domain and subdomains, compared as lowercase punycode), checks wrapped `blob:`/`view-source:`/`filesystem:` URLs by their inner URL, and drops browser-extension pages. It fails closed on URLs it cannot check, including host-less schemes other than `about:` and `data:`. URLs are redacted to `scheme://host[:port]/path` (query, fragment, credentials and `;` parameters dropped; optional host-only mode). `Blocklist` holds exact or `.*` prefix bundle-ID patterns and domains, with default exclusions for password managers, messaging and mail apps, and password-manager, messaging, banking and payment sites. The defaults are listed in docs/PRIVACY.md, and a test keeps that list in sync with the code. User entries extend the defaults. Unit tests prove excluded fixture activity never reaches the repository, the database or its files.

### Changed
- `ActivityRepository.insert(_:)` now takes a `FilteredEvent`, so excluded or unredacted activity cannot be stored by construction. `ActivityEvent` is read-only (no longer persistable) and redacts its window title and URL (as does `ActivitySample`) in `description`, `debugDescription` and `dump`. GRDB `publicStatementArguments` is set off explicitly, with a test (#20).
- `CaptureStateStore` is now owned by an `AppModel` held by the app delegate instead of the SwiftUI `App` struct (#15).
