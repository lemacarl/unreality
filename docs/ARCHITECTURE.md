# Architecture

Stack: native Swift ([ADR 0001](decisions/0001-technology-stack.md)). Status: scaffold plus a menu-bar status item and popover driven by `CaptureStateStore` (#12), the Keychain secret store (#14), the SQLite storage layer (#16), a global pause hotkey (#15), a settings window backed by `SettingsStore` (#13) the frontmost app / window title activity source (#17, not yet wired into the app) and the privacy filter in front of storage (#20); no capture is recorded yet.

```mermaid
flowchart LR
  subgraph Platform[UnrealityPlatform - real OS integrations]
    A[ActivitySource] --- S[ScreenCapturer + OCRService] --- F[FaceDetector] --- K[KeychainSecretStore] --- C[AIClient impl]
  end
  subgraph Core[UnrealityCore - pure logic, fakes in tests]
    P[Privacy filter / blocklist] --> D[Dedupe + scheduler]
    D --> L[Event log]
    L --> DB[(SQLite via GRDB)]
    DB --> SUM[Summariser]
  end
  Platform --> P
  SUM --> C
  DB --> UI[SwiftUI menu bar, settings, timeline]
```

## Modules
- **UnrealityCore** — domain types, scheduler, dedupe, privacy filtering, retention, summarisation orchestration, storage schema. No OS imports.
- **UnrealityPlatform** — real implementations of every protocol.
- **App** — SwiftUI/AppKit shell, generated via XcodeGen.

## Menu bar and capture state
- `CaptureStateStore` (UnrealityCore) is the single source of truth for whether capture is `running` or `paused`. It is `@MainActor` and `@Observable` (Observation framework), exposes `state`, `isPaused`, `pause()`, `resume()`, `toggle()` and `onChange(_:)` (synchronous, cancellable change handlers for non-UI code such as `ActivityCoordinator`), ignores same-state writes, and starts in `running`. It holds state only; it is not persisted across launches. The global pause hotkey (#15) calls `toggle()`, and the capture pipeline (M3) will observe it.
- The app owns one store via `AppModel` (App/Sources/AppModel.swift), which `AppDelegate` (wired with `@NSApplicationDelegateAdaptor`) creates and keeps for the app's lifetime, so the global hotkey handler and SwiftUI share it. `UnrealityApp` shows it through a SwiftUI `MenuBarExtra` with `.window` style (a popover-like panel). The status item is a template SF Symbol (`eye` running, `eye.slash` paused) so macOS tints it for light and dark menu bars. The popover shows the state, a Pause/Resume button and Quit (Cmd-Q). Display strings and symbol names live in the app (`StatusPopover.swift`), not the core.
- The popover also shows the pause shortcut, or that it could not be registered, and a "Settings…" button (Cmd-,) that opens the settings window (see [Settings](#settings)).
- `MenuBarExtra` is sufficient for now; switch to `NSStatusItem` + `NSPopover` (ADR 0001) only if it proves limiting.

## Time and hotkeys
Protocols in UnrealityCore, real implementations in UnrealityPlatform, fakes in the core so tests and later features use them:

| Protocol (core) | Real (platform) | Fake (core) |
|---|---|---|
| `WallClock` (named to avoid `Swift.Clock`): `now()` | `SystemClock` | `FakeTime` |
| `Scheduler`: `schedule(after:repeating:_:)` returning a cancellable `ScheduledWork` | `DispatchScheduler` (`DispatchSourceTimer` on a given queue) | `FakeTime`: time moves only on `advance(by:)`, which runs due work in order |
| `HotkeyRegistrar` (`@MainActor`) | `CarbonHotkeyRegistrar` (`RegisterEventHotKey`; no Accessibility or Input Monitoring permission, sees only its own combination) | `FakeHotkeyRegistrar` with `press(_:)` |

`PauseHotkeyController` (core) binds a `Hotkey` to `CaptureStateStore.toggle()`. The default is `Hotkey.defaultPause`, Control-Option-Command-P (key code 35: a physical key position, labelled P on QWERTY layouts; other layouts may show a different letter there, and deriving the label from the layout is for the settings UI); override it in code via `AppModel(pauseHotkey:)`; the settings window shows it read-only and rebinding is not built yet. If registration fails the app logs the OS status and the popover says the shortcut could not be registered; it does not guess why. Only refusals the OS reports are detectable (for example `eventHotKeyExistsErr` for a combination already registered in this process). A combination held by another app, or a system shortcut, is not detected: `RegisterEventHotKey` returns `noErr` and presses may never arrive. So the menu-bar icon and popover, not the shortcut, are the source of truth for pause state. `CarbonHotkeyRegistrar` and `PauseHotkeyController` release their registrations in `deinit`, so they must be released on the main thread (their main-actor owner, `AppModel`, ensures this). Launch at login (`LoginItemService` via `SMAppService`) is tracked in #56.

## Activity source
Frontmost app and focused window title (#17). Protocols and fakes in UnrealityCore, real implementations in UnrealityPlatform; all main-actor bound and event driven (no polling).

| Protocol (core) | Real (platform) | Fake (core) |
|---|---|---|
| `ActivitySource`: `start(windowTitlePolicy:handler:)`, `stop()` | `WorkspaceActivitySource` | `FakeActivitySource` with `activate(_:title:)` and `setTitle(_:)` |
| `AccessibilityTrust`: `currentState()` (never prompts), `requestAccess()` (prompts; explicit user action only) | `SystemAccessibilityTrust` (`AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`) | `FakeAccessibilityTrust` |

- **`ActivitySample`** is the raw, unfiltered sample type the privacy filter (#20) wraps: `timestamp`, `trigger` (`snapshot` on start/resume, `appActivated`, `titleChanged`), `app` (`FrontmostApp`: bundle ID, localised name, process ID) and an optional `windowTitle`. It is not a storage record; turning samples into `ActivityEvent` spans is a later pipeline step.
- **`WorkspaceActivitySource`** listens for `NSWorkspace.didActivateApplicationNotification`. Before reading a title it asks the `WindowTitlePolicy` closure; only if that allows it does it look up `kAXFocusedWindowAttribute`, read that window's `kAXTitleAttribute` via `AXUIElement`, and register an `AXObserver` on that one app for `kAXFocusedWindowChangedNotification` and the focused window's `kAXTitleChangedNotification` (run-loop source in the main run loop's common modes). Unreality's own process is always app-only: the policy is not asked and no AX call or observer targets it. The observer is torn down on every app switch, on `stop` and when the policy later says no. `titleChanged` is emitted only when the title actually changes. Every AX call is a synchronous round trip on the main thread. A 0.25 s messaging timeout is set on the app element and on each window element used (it applies per element), the focused window found when subscribing is reused for the title read, and AX calls stop after the first `kAXErrorCannotComplete` until the app sends a notification or is activated again. So an unresponsive app costs roughly one timeout per activation (a few in the worst case), not the system default of about 6 s per call.
- **`ActivityCoordinator`** (core, `@Observable`) is the integration seam. It stops the source while `CaptureStateStore` is paused (so nothing is read) and restarts it on resume with a fresh snapshot, and drops any sample that arrives while paused or after `stop`. It reacts synchronously through `CaptureStateStore.onChange(_:)`, so a pause takes effect before anything else is read. It re-checks Accessibility trust on every sample and publishes it as `accessibilityTrust` (for a future settings/onboarding UI); without trust samples are app-only and title changes are dropped, even if a source ignored the policy. It never prompts. Trust granted while an app stays frontmost is picked up when the app calls `refreshAccessibilityTrust()` (for example when it becomes active again after System Settings), which restarts the source with a fresh snapshot if active and running; otherwise at the next app switch. It never allows titles for a process without a bundle ID (no exclusion list could match it) or for Unreality's own process. It requires an `ActivitySampleFilter` (`allowsWindowTitle(for:)` before any title is read, `filter(_:)` on every sample): there is deliberately no pass-through filter in the sources, so nothing can wire the coordinator unfiltered; the privacy filter (#20) provides the real one.
- Browser URLs (#19) and idle time (#18) are separate sources.

## Repository layout
| Path | Contents |
|---|---|
| `Package.swift` | SwiftPM manifest: `UnrealityCore`, `UnrealityPlatform` libraries and their test targets |
| `Sources/UnrealityCore` | Pure logic, the privacy filter (`Privacy/`) and storage (`Storage/`). Allow-listed imports only (Foundation, Dispatch, Observation, Synchronization, RegexBuilder, GRDB); other imports are a lint error (`core_no_os_imports`, and `core_tests_no_os_imports` for `Tests/UnrealityCoreTests`, which also allows UnrealityCore and Testing). Regex-based guard, backed in CI by a compiler check of the module's actual imports (`scripts/ci/check-core-imports.py`) |
| `scripts/ci/` + `.github/workflows/ci.yml` | CI workflow and its guard scripts; pinned tool versions in `scripts/ci/tool-versions.env` |
| `Sources/UnrealityPlatform` | Real OS integrations; depends on the core |
| `Tests/` | Swift Testing suites per library |
| `App/` + `project.yml` | Menu-bar app shell (`LSUIElement`, macOS 14, bundle ID `com.lemacarl.unreality`); `Unreality.xcodeproj` is generated by XcodeGen and gitignored |
| `App/Sources` | `UnrealityApp` (scenes), `AppModel`/`AppDelegate`, `StatusPopover`, `SettingsView` |
| `Config/` | `Signing.xcconfig` (ad-hoc default) with an optional, gitignored `Local.xcconfig` override |

## Swift language mode
**Swift 6 language mode** for every target (`swiftLanguageModes: [.v6]` in `Package.swift`, `SWIFT_VERSION = 6.0` in `project.yml`), built with the Swift 6.2 toolchain (Xcode 26). Reasons: complete strict concurrency checking from the first line of code is far cheaper than migrating later, and the capture/OCR/presence pipeline is concurrent by nature, so data races should be compile errors. Tools version is 6.0 so slightly older Swift 6 toolchains (e.g. on CI runners) still resolve the package. Tests use Swift Testing.

Considered and not enabled: Swift 6.2's default MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` / `.defaultIsolation(MainActor.self)`) and the "approachable concurrency" upcoming features. Most of the code is background capture, OCR and storage, so implicit MainActor isolation would push work onto the UI thread by default, and the packages and the app shell should share one set of rules. UI types are annotated `@MainActor` explicitly. Revisit for the App target if the annotation noise grows.

Revisit the mode if a required Apple framework is unusable under strict concurrency; in UnrealityPlatform prefer a local `@preconcurrency import` over dropping the mode (in UnrealityCore the import allow-list still applies).

## Settings
Non-secret user configuration (#13). Protocol and typed values in UnrealityCore (`Settings.swift`), the real store in UnrealityPlatform:

| Type | Module | Role |
|---|---|---|
| `SettingValue` | core | Property-list primitive a store can hold (`Int`, `Bool`). `SecretValue` does not conform, so a secret cannot be written to settings |
| `SettingKey<Value>` | core | Storage name, default and sanitiser (integer keys clamp to a range). Missing or wrong-typed stored values read as the default; out-of-range ones are clamped on read and write. Shipped names are never renamed |
| `AppSettings` | core | The settings that exist so far (below) and `allNames` |
| `SettingsStore` | core | `value(for:)`, `setValue(_:for:)`, `removeValue(for:)`; `Sendable`, synchronous |
| `InMemorySettingsStore` | core | Fake for tests and previews (`setRawObject` simulates stale or hand-edited data) |
| `UserDefaultsSettingsStore` | platform | Real store; the app uses `UserDefaults.standard` (domain `com.lemacarl.unreality`), tests a throwaway suite |
| `SettingsModel` | core | `@MainActor @Observable` cache over a store for SwiftUI: `model[key]` reads and writes (sanitised, written through at once), `reset(_:)` restores the default |

Contract (unset reads as default, set replaces, remove restores the default and is idempotent, keys independent, wrong types read as the default) is unit-tested against the fake (`SettingsStoreContractTests`) and against UserDefaults (`UserDefaultsSettingsStoreTests`, including persistence across store instances).

| Setting (`AppSettings`) | Default | Range | Read by |
|---|---|---|---|
| `idleThresholdMinutes` | 5 | 1–60 | idle detection (#18); placeholder, unused |
| `rawCaptureRetentionHours` | 24 | 1–24 | raw-capture retention job (#27), which sets the final default; placeholder, not enforced |
| `contentRetentionDays` | 30 | 1–365 | capture store / retention (#26), which sets the final default; placeholder, not enforced |

The window is a SwiftUI `Settings` scene (`App/Sources/SettingsView.swift`) with tabs General (pause shortcut, read-only, and whether it registered; rebinding is not built), Capture (idle threshold; screen capture stub), Privacy (retention windows; blocklist stub) and AI (stub; the API key will go to the Keychain, never settings). `AppModel` owns the `SettingsModel`. Because the app is `LSUIElement`, the popover activates the app before calling `openSettings` so the window comes to the front. Launch at login is #56.

## Secrets
Secrets (the Claude API key) live only in the macOS Keychain (#14). `UnrealityCore` declares the `SecretStore` protocol (ADR 0001 calls it `KeychainStore`), the `SecretKey` / `SecretValue` types, `SecretStoreError`, and the `InMemorySecretStore` fake used by tests and previews. `UnrealityPlatform` has `KeychainSecretStore`, built on the Security framework.

- Each secret is a generic-password item: service = the store's namespace, account = `SecretKey.rawValue` (the API key is `claude-api-key`). The app uses the default service, the bundle ID `com.lemacarl.unreality`; tests inject a unique service so they never touch real items.
- Items live in the login (file-based) keychain, not the data-protection keychain, which would need a keychain-access-groups entitlement and a real signing identity. Items are not synchronised to iCloud. macOS may ask the user to allow access when the app's signing identity changes (for example between ad-hoc builds).
- No logging of secret values. `SecretValue` redacts itself in `description`, `debugDescription`, string interpolation and `dump`; the plaintext is only available through `reveal()` at the point of use. `SecretStoreError` carries only the key name and a status code.
- Contract (get missing = `nil`, set inserts or replaces, remove is idempotent, keys independent) is unit-tested against the fake; the same checks run against the real Keychain only on demand (`UNREALITY_KEYCHAIN_TESTS=1`, see CONTRIBUTING.md, "Manual checks").
- The settings UI for entering the key arrives in M5.

## Privacy filter
`Sources/UnrealityCore/Privacy` (#20): a pure function layer between capture sources and storage, with no capture or UI code. Behaviour, defaults and limits: [PRIVACY.md](PRIVACY.md#privacy-filter).

- Capture sources report an `ActivitySample` (raw, with the unredacted URL). `PrivacyFilter.evaluate(_:)` returns `.keep(FilteredEvent)` or `.drop(PrivacyDropReason)` (`excludedApp`, `excludedSite`, `uncheckableURL`; reasons carry no captured data). `filter(_:)` returns the event or `nil`, and also takes a batch.
- `PrivacyFilter(blocklist:urlRedaction:)` defaults to `Blocklist.defaults` (built from `DefaultExclusions`) and `URLRedaction.keepPath`. User entries are added with `Blocklist.defaults.union(Blocklist(bundleIDPatterns:domains:))`; persisting them and the settings UI come in M6.
- `FilteredEvent` has a `fileprivate` initialiser in `PrivacyFilter.swift` and is not `Decodable`, so only the filter creates one. `ActivityRepository.insert(_:)` takes only a `FilteredEvent`; the convenience `insert(_:filteredBy:)` filters a sample and stores the result, returning `nil` (and writing nothing) when it was dropped. `ActivityEvent`, the read model, is `FetchableRecord` but not persistable: the GRDB repository writes rows through an internal `EventInsertRecord` built from a `FilteredEvent`. Repository fakes build their return value with `ActivityEvent(_:id:)`.
- `ActivitySample`, `FilteredEvent` and `ActivityEvent` redact window titles and URLs in `description`, `debugDescription` and `dump`. Never log titles or URLs.

## Data flow
Platform sources emit samples (`ActivityCoordinator` gates them on pause state and Accessibility trust) → privacy filter drops excluded apps/sites (before capture or OCR where possible, always before storage) → dedupe skips unchanged screens → events/OCR text/presence booleans written to SQLite → retention job deletes raw captures after the window → summariser sends text only to the Claude API.

## Storage
SQLite via GRDB.swift 7.11.1 ([ADR 0002](decisions/0002-initial-dependencies.md)), in `Sources/UnrealityCore/Storage` (#16).

- **`DatabaseManager`** opens the database and runs all pending migrations before returning. `open(in:)` takes an injectable directory (the app passes `defaultDirectory()`, `~/Library/Application Support/com.lemacarl.unreality`) and opens `unreality.sqlite` there, setting the folder to 0700 and the database, `-wal` and `-shm` files to 0600 on every open; `inMemory()` gives each test a private, migrated database. Every connection sets `PRAGMA secure_delete = ON`; GRDB enables foreign keys. `publicStatementArguments` is set off explicitly (never turn it on), so GRDB errors and traces never include stored values such as titles and URLs.
- **Migrations** (`Migrations.swift`) use GRDB's `DatabaseMigrator`, which records applied identifiers in `grdb_migrations` and runs each once, in order, from an empty file. Shipped migrations are never edited; schema changes add a new one. `appliedMigrations()` lists what ran.
- **`ActivityRepository`** (protocol) is the storage API for the rest of the app; `GRDBActivityRepository` implements it. Its insert accepts only a `FilteredEvent` (see Privacy filter). Fakes for other features conform to the protocol. Retention jobs (#26, #27) call its `deleteEvents(endedBefore:)` (events whose `ended_at` is strictly before the cutoff; an event spanning it stays) and `deleteSessions(endedBefore:)` (closed sessions only; open sessions are never deleted) hooks. Both then run `wal_checkpoint(TRUNCATE)`: with `secure_delete`, deleted pages are zeroed in the main file once checkpointed, but `-wal` may retain old page images until it is truncated, which automatic (PASSIVE) checkpoints never do.

### Schema (migration `v1_events_sessions`)
Dates are GRDB `datetime` values: UTC text `YYYY-MM-DD HH:MM:SS.SSS` (millisecond precision, sorts chronologically).

`sessions` — a continuous stretch of tracked work.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | |
| `started_at` | DATETIME NOT NULL | indexed |
| `ended_at` | DATETIME NULL | `NULL` while open; CHECK `ended_at >= started_at` |

`events` — one span of activity.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | |
| `kind` | TEXT NOT NULL | `app`, `web` or `idle` (`ActivityEventKind`); no CHECK, so new kinds need no table rebuild |
| `app_bundle_id` | TEXT NULL | frontmost app; `NULL` for idle |
| `window_title` | TEXT NULL | |
| `url` | TEXT NULL | web only; redacted by the privacy filter (no query, fragment or credentials) |
| `started_at` | DATETIME NOT NULL | indexed |
| `ended_at` | DATETIME NOT NULL | indexed (retention); CHECK `ended_at >= started_at` |
| `source` | TEXT NOT NULL | capture source that produced the event |
| `session_id` | INTEGER NULL | FK `sessions(id)` ON DELETE SET NULL; indexed |

Range queries are half-open overlaps (`started_at < end AND ended_at > start`; open sessions count as ongoing), so a zero-length event at exactly the interval start, or any zero-length interval, matches nothing. Only data that passed the privacy filter is written (see [PRIVACY.md](PRIVACY.md)).

### Threading
File-backed databases use a GRDB `DatabasePool`: WAL mode, concurrent reads, one serialised writer. In-memory databases use a `DatabaseQueue` (one serialised connection). Both are thread-safe, so `DatabaseManager` and the repository are `Sendable`. Repository calls are synchronous and block until done: call them from background actors (capture, retention), never on the main actor. A read path for the UI (for example GRDB `ValueObservation`) is left to the timeline issue.
