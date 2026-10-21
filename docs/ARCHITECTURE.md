# Architecture

Stack: native Swift ([ADR 0001](decisions/0001-technology-stack.md)). Status: scaffold plus a menu-bar status item and popover driven by `CaptureStateStore` (#12), the Keychain secret store (#14), the SQLite storage layer (#16), a global pause hotkey (#15), a settings window backed by `SettingsStore` (#13), the frontmost app / window title activity source (#17, not yet wired into the app), the privacy filter in front of storage (#20), session aggregation of samples into stored events and sessions (#21, not yet wired into the app) and launch at login via `SMAppService` (#56); no capture is recorded yet.

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

`PauseHotkeyController` (core) binds a `Hotkey` to `CaptureStateStore.toggle()`. The default is `Hotkey.defaultPause`, Control-Option-Command-P (key code 35: a physical key position, labelled P on QWERTY layouts; other layouts may show a different letter there, and deriving the label from the layout is for the settings UI); override it in code via `AppModel(pauseHotkey:)`; the settings window shows it read-only and rebinding is not built yet. If registration fails the app logs the OS status and the popover says the shortcut could not be registered; it does not guess why. Only refusals the OS reports are detectable (for example `eventHotKeyExistsErr` for a combination already registered in this process). A combination held by another app, or a system shortcut, is not detected: `RegisterEventHotKey` returns `noErr` and presses may never arrive. So the menu-bar icon and popover, not the shortcut, are the source of truth for pause state. `CarbonHotkeyRegistrar` and `PauseHotkeyController` release their registrations in `deinit`, so they must be released on the main thread (their main-actor owner, `AppModel`, ensures this). Launch at login: see [Launch at login](#launch-at-login).

## Activity source
Frontmost app and focused window title (#17). Protocols and fakes in UnrealityCore, real implementations in UnrealityPlatform; all main-actor bound and event driven (no polling).

| Protocol (core) | Real (platform) | Fake (core) |
|---|---|---|
| `ActivitySource`: `start(windowTitlePolicy:handler:)`, `stop()` | `WorkspaceActivitySource` | `FakeActivitySource` with `activate(_:title:)` and `setTitle(_:)` |
| `AccessibilityTrust`: `currentState()` (never prompts), `requestAccess()` (prompts; explicit user action only) | `SystemAccessibilityTrust` (`AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`) | `FakeAccessibilityTrust` |

- **`ActivitySample`** is the raw, unfiltered sample type the privacy filter (#20) checks: `timestamp`, `trigger` (`snapshot` on start/resume, `appActivated`, `titleChanged`), `app` (`FrontmostApp`: bundle ID, localised name, process ID) and an optional `windowTitle`. It is not a storage record; turning samples into `ActivityEvent` spans is a later pipeline step.
- **`WorkspaceActivitySource`** listens for `NSWorkspace.didActivateApplicationNotification`. Before reading a title it asks the `WindowTitlePolicy` closure; only if that allows it does it look up `kAXFocusedWindowAttribute`, read that window's `kAXTitleAttribute` via `AXUIElement`, and register an `AXObserver` on that one app for `kAXFocusedWindowChangedNotification` and the focused window's `kAXTitleChangedNotification` (run-loop source in the main run loop's common modes). Unreality's own process is always app-only: the policy is not asked and no AX call or observer targets it. The observer is torn down on every app switch, on `stop` and when the policy later says no. `titleChanged` is emitted only when the title actually changes. Every AX call is a synchronous round trip on the main thread. A 0.25 s messaging timeout is set on the app element and on each window element used (it applies per element), the focused window found when subscribing is reused for the title read, and AX calls stop after the first `kAXErrorCannotComplete` until the app sends a notification or is activated again. So an unresponsive app costs roughly one timeout per activation (a few in the worst case), not the system default of about 6 s per call.
- **`ActivityCoordinator`** (core, `@Observable`) is the integration seam. It stops the source while `CaptureStateStore` is paused (so nothing is read) and restarts it on resume with a fresh snapshot, and drops any sample that arrives while paused or after `stop`. It reacts synchronously through `CaptureStateStore.onChange(_:)`, so a pause takes effect before anything else is read. It re-checks Accessibility trust on every sample and publishes it as `accessibilityTrust` (for a future settings/onboarding UI); without trust samples are app-only and title changes are dropped, even if a source ignored the policy. It never prompts. Trust granted while an app stays frontmost is picked up when the app calls `refreshAccessibilityTrust()` (for example when it becomes active again after System Settings), which restarts the source with a fresh snapshot if active and running; otherwise at the next app switch. It never allows titles for a process without a bundle ID (no exclusion list could match it) or for Unreality's own process. It requires an `ActivitySampleFilter` (`allowsWindowTitle(for:)` before any title is read, `filter(_:)` on every sample): there is deliberately no pass-through filter in the sources, so nothing can wire the coordinator unfiltered; the privacy filter (#20) provides the real one. It also requires a `WallClock`, for the time of pause and stop boundaries. `start(_:)` delivers samples only; `startSignals(_:)` delivers `ActivitySignal`s: `.sample`, or `.boundary(ActivityBoundary)`, an anonymous marker carrying only a timestamp, sent where tracked activity stops: at the time of a sample the filter dropped (an excluded app became frontmost), and at the clock's time on pause and on `stop()`. A title change dropped for lack of Accessibility trust is not a boundary (the same app is still in use). See [Session aggregation](#session-aggregation).
- Browser URLs (#19) and idle time (#18) are separate sources.

## Repository layout
| Path | Contents |
|---|---|
| `Package.swift` | SwiftPM manifest: `UnrealityCore`, `UnrealityPlatform` libraries and their test targets |
| `Sources/UnrealityCore` | Pure logic, the privacy filter (`Privacy/`), session aggregation (`Aggregation/`) and storage (`Storage/`). Allow-listed imports only (Foundation, Dispatch, Observation, Synchronization, RegexBuilder, GRDB); other imports are a lint error (`core_no_os_imports`, and `core_tests_no_os_imports` for `Tests/UnrealityCoreTests`, which also allows UnrealityCore and Testing). Regex-based guard, backed in CI by a compiler check of the module's actual imports (`scripts/ci/check-core-imports.py`) |
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

The window is a SwiftUI `Settings` scene (`App/Sources/SettingsView.swift`) with tabs General (launch at login; pause shortcut, read-only, and whether it registered; rebinding is not built), Capture (idle threshold; screen capture stub), Privacy (retention windows; blocklist stub) and AI (stub; the API key will go to the Keychain, never settings). `AppModel` owns the `SettingsModel`. Because the app is `LSUIElement`, the popover activates the app before calling `openSettings` so the window comes to the front.

## Launch at login
Launch at login (#56, ADR 0001: `SMAppService`). Protocol, fake and model in UnrealityCore (`LoginItem.swift`), the real service in UnrealityPlatform:

| Type | Module | Role |
|---|---|---|
| `LoginItemService` (`@MainActor`) | core | `status()` (no side effects), `register()`, `unregister()` (typed throws `LoginItemError`), `openLoginItemsSettings()` |
| `LoginItemStatus` | core | `notRegistered`, `enabled`, `requiresApproval`, `notFound`; `isRequested` is true for `enabled` and `requiresApproval` |
| `LoginItemError` | core | Operation plus the error's domain and code only (no localised text, which may name paths), so it is safe to log |
| `FakeLoginItemService` | core | Test double: settable status, injectable errors, call counts |
| `LaunchAtLoginModel` | core | `@MainActor @Observable`, owned by `AppModel`: `status`, `isEnabled`, `lastError`, `refresh()`, `setEnabled(_:)`, `openLoginItemsSettings()` |
| `SMAppServiceLoginItemService` | platform | `SMAppService.mainApp` (the app itself, no helper bundle); `SMAppService.openSystemSettingsLoginItems()` |

- **macOS is the source of truth.** The status is read from `SMAppService` on every `refresh()` and after every change, never cached across launches or mirrored into settings/UserDefaults, because the user can change it in System Settings > General > Login Items at any time. The General tab re-reads it when it appears and whenever the app becomes active again.
- **Off by default, never silent.** Nothing registers at launch or on first run; only the user's toggle calls `setEnabled(_:)`. A toggle to the state already in effect calls nothing.
- **`requiresApproval`** (registered, but the user must allow it in Login Items) shows the toggle as on, explains that approval is needed and offers an "Open Login Items Settings…" button.
- **Errors** are kept in `lastError` and shown in the tab with the code; the status is re-read either way, and once the status shows the request took effect despite the error (right away, or on a later `refresh()`, for example after the user fixed it in System Settings), the error is dropped. Unknown future statuses map to `notFound` (off).
- Registration needs a signed app in a stable location; ad-hoc and unsigned dev builds may report `notFound`, fail, or leave stale entries (CONTRIBUTING.md, "Manual checks"). Unit tests use the fake; only the status and error mapping of the real service is unit-tested.

## Secrets
Secrets (the Claude API key) live only in the macOS Keychain (#14). `UnrealityCore` declares the `SecretStore` protocol (ADR 0001 calls it `KeychainStore`), the `SecretKey` / `SecretValue` types, `SecretStoreError`, and the `InMemorySecretStore` fake used by tests and previews. `UnrealityPlatform` has `KeychainSecretStore`, built on the Security framework.

- Each secret is a generic-password item: service = the store's namespace, account = `SecretKey.rawValue` (the API key is `claude-api-key`). The app uses the default service, the bundle ID `com.lemacarl.unreality`; tests inject a unique service so they never touch real items.
- Items live in the login (file-based) keychain, not the data-protection keychain, which would need a keychain-access-groups entitlement and a real signing identity. Items are not synchronised to iCloud. macOS may ask the user to allow access when the app's signing identity changes (for example between ad-hoc builds).
- No logging of secret values. `SecretValue` redacts itself in `description`, `debugDescription`, string interpolation and `dump`; the plaintext is only available through `reveal()` at the point of use. `SecretStoreError` carries only the key name and a status code.
- Contract (get missing = `nil`, set inserts or replaces, remove is idempotent, keys independent) is unit-tested against the fake; the same checks run against the real Keychain only on demand (`UNREALITY_KEYCHAIN_TESTS=1`, see CONTRIBUTING.md, "Manual checks").
- The settings UI for entering the key arrives in M5.

## Privacy filter
`Sources/UnrealityCore/Privacy` (#20): a pure function layer between capture sources and storage, with no capture or UI code. Behaviour, defaults and limits: [PRIVACY.md](PRIVACY.md#privacy-filter).

- **`PrivacyRules`** (`Sendable` value, usable off the main actor) holds the `Blocklist` (default `Blocklist.defaults`, built from `DefaultExclusions`) and the `URLRedaction` (default `keepPath`). It answers two questions:
  - `allowsWindowTitle(for: FrontmostApp)`: false for excluded apps and for apps without a bundle ID.
  - `filter(_: ActivitySample) -> ActivitySample?`: drops excluded apps (including app-only samples) and strips the title of an app without a bundle ID.

  It also builds the only storable type:
  - `evaluate(_:until:url:source:sessionID:)` returns `.keep(FilteredEvent)` or `.drop(PrivacyDropReason)`. The reasons are `excludedApp`, `excludedSite`, `uncheckableURL` and `excludedExtensionPage`, and they carry no captured data.
  - `event(from:until:url:source:sessionID:)` is the optional form; `idleEvent(from:until:source:sessionID:)` builds an idle span.

  Building an event re-applies `filter(_:)`, so a raw sample cannot bypass it. A URL makes a `.web` event, after the site check and redaction (in `URLRedaction.swift`): wrapped `blob:`/`view-source:`/`filesystem:` URLs are checked by their inner URL; extension pages are dropped; host-less URLs fail closed, except `about:` and `data:`; hosts are canonical (percent escapes decoded, lowercase punycode, `Blocklist.canonicalHost`), and a host that cannot be made canonical fails closed.
- **`PrivacyFilter`** (`@MainActor` class) is the real `ActivitySampleFilter` that `ActivityCoordinator` (#17) requires. It delegates to its `rules`, which can be replaced at runtime (for example when the user edits the blocklist, M6). User entries are added with `Blocklist.defaults.union(Blocklist(bundleIDPatterns:domains:))`. The app keeps one instance as the single source of truth for the user's rules. The pipeline builds events with that instance's `evaluate`/`event`/`idleEvent` on the main actor, then hands the `Sendable` `FilteredEvent` to storage, rather than keeping a `PrivacyRules` copy that could go stale.
- `FilteredEvent` has a `fileprivate` initialiser in `PrivacyFilter.swift` and is not `Decodable`, so only the rules create one. It has no process ID or app name. `ActivityRepository.insert(_:)` takes only a `FilteredEvent`. Redaction therefore holds by construction outside the storage layer. Exclusion holds only if events are built with the user's rules: any code can create `PrivacyRules(blocklist: .empty)`. Code inside `UnrealityCore` with `DatabaseManager`'s internal writer could also write rows directly; only the repository may use it. `ActivityEvent`, the read model, is `FetchableRecord` but not persistable: the GRDB repository writes rows through an internal `EventInsertRecord` built from a `FilteredEvent`. Repository fakes build their return value with `ActivityEvent(_:id:)`.
- Turning consecutive samples into spans is `SpanAggregator` and `ActivityPipeline` (#21, see [Session aggregation](#session-aggregation)), which build every event through the single `PrivacyFilter` instance when the span completes. `FilteredEvent.inSession(_:)` reassigns only the session ID, for the writer that learns it after the event was built. Browser URLs arrive with #19, which will also move the site check into `filter(_:)`.
- `ActivitySample`, `FilteredEvent` and `ActivityEvent` redact window titles and URLs in `description`, `debugDescription` and `dump`. Never log titles or URLs.

## Session aggregation
`Sources/UnrealityCore/Aggregation` (#21): turns filtered samples into stored events and sessions. Pure logic plus one writer; nothing here reads the system.

- **`SpanAggregator`** (`Sendable` value, no clock, no I/O, deterministic for a given input sequence and `Calendar`) consumes `.sample`, `.boundary`, `.idleStarted` and `.idleEnded` inputs and emits `.sessionStarted`, `.activity(sample, until:)`, `.idle(DateInterval)` and `.sessionEnded`. `aggregate(_:calendar:endingAt:)` runs a whole fixture. Rules:
  - A span lasts from its sample to the next input that changes what is in use. A sample equal to the open span's in everything that is stored (bundle ID, window title, and fields added to `ActivitySample` later, such as a URL; not the time, trigger, process ID or display name) continues it. So a second `.snapshot` for the same app (a restart after a trust grant, #67) adds nothing, and one that now has a title starts a new span, like a title change.
  - A boundary ends the open span (activity or idle) and the session, and forgets the frontmost app, so time in an excluded app, while paused or after stop is attributed to nothing.
  - `idleStarted` ends the activity span and the session and opens an idle span; `idleEnded` closes it and resumes the app that was frontmost (unless a boundary came in between) in a new session; a sample while idle ends the idle span. Repeated or unmatched idle inputs are ignored. Idle detection itself is #18.
  - Spans are split at local midnight (per the `Calendar`, so time zones and daylight saving are respected): every span lies within one day. Sessions are not split.
  - Zero-length spans and empty sessions are never emitted. An input earlier than the previous one counts as happening at the previous one, so spans never overlap.
- **`ActivityPipeline`** (`@MainActor`) feeds `ActivityCoordinator.startSignals(_:)` and idle transitions into the aggregator, builds each completed span's `FilteredEvent` through the app's single `PrivacyFilter` (with its rules at that moment, so an app excluded while its span was open is dropped), and passes `ActivityRecordCommand`s (`startSession`, `insert(FilteredEvent)`, `endSession`) to an `ActivityRecordWriter`. A written session runs from its first stored event to its last, and a dropped span ends it like a boundary, so no session covers dropped time and none is empty. Idle events have no session. `finish(at:)` writes what is still open (for example at quit); until a span completes it is held only in memory.
- **`RepositoryRecordWriter`** applies the commands to an `ActivityRepository` on a private serial queue (repository calls block, so never on the main actor), assigns activity events to the open session (`FilteredEvent.inSession(_:)`), and stores events without a session if opening one failed. Errors go to an `onError` handler.
- Boundaries and excluded time are never stored: there is no gap row, the timeline simply has no event there. No schema change was needed (`v1_events_sessions` already has `sessions` and `events.session_id`).
- Tests: fixture tests for rapid switching, title changes, duplicate snapshots, idle, excluded-app switching, pause/resume, midnight in several time zones and out-of-order input (`SpanAggregatorTests`); coordinator boundaries (`CoordinatorBoundaryTests`); the pipeline end to end on an in-memory database, including live rule changes (`ActivityPipelineTests`).

## Data flow
Platform sources emit samples (`ActivityCoordinator` gates them on pause state and Accessibility trust) → privacy filter drops excluded apps/sites (before capture or OCR where possible, always before storage; the coordinator sends an anonymous boundary in place of a dropped sample) → `ActivityPipeline` aggregates samples, boundaries and idle transitions into spans and sessions and builds `FilteredEvent`s through the live `PrivacyFilter` → dedupe skips unchanged screens → events/OCR text/presence booleans written to SQLite → retention job deletes raw captures after the window → summariser sends text only to the Claude API.

## Storage
SQLite via GRDB.swift 7.11.1 ([ADR 0002](decisions/0002-initial-dependencies.md)), in `Sources/UnrealityCore/Storage` (#16).

- **`DatabaseManager`** opens the database and runs all pending migrations before returning. `open(in:)` takes an injectable directory (the app passes `defaultDirectory()`, `~/Library/Application Support/com.lemacarl.unreality`) and opens `unreality.sqlite` there, setting the folder to 0700 and the database, `-wal` and `-shm` files to 0600 on every open; `inMemory()` gives each test a private, migrated database. Every connection sets `PRAGMA secure_delete = ON`; GRDB enables foreign keys. `publicStatementArguments` is set off explicitly (never turn it on), so GRDB errors and traces never include stored values such as titles and URLs.
- **Migrations** (`Migrations.swift`) use GRDB's `DatabaseMigrator`, which records applied identifiers in `grdb_migrations` and runs each once, in order, from an empty file. Shipped migrations are never edited; schema changes add a new one. `appliedMigrations()` lists what ran.
- **`ActivityRepository`** (protocol) is the storage API for the rest of the app; `GRDBActivityRepository` implements it, and `RepositoryRecordWriter` (see Session aggregation) writes events and sessions through it. Its insert accepts only a `FilteredEvent` (see Privacy filter). Fakes for other features conform to the protocol. Retention jobs (#26, #27) call its `deleteEvents(endedBefore:)` (events whose `ended_at` is strictly before the cutoff; an event spanning it stays) and `deleteSessions(endedBefore:)` (closed sessions only; open sessions are never deleted) hooks. Both then run `wal_checkpoint(TRUNCATE)`: with `secure_delete`, deleted pages are zeroed in the main file once checkpointed, but `-wal` may retain old page images until it is truncated, which automatic (PASSIVE) checkpoints never do.

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
