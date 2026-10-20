# Privacy

Target behaviour (implemented so far: Keychain storage of the API key (#14), local SQLite storage (#16), the global pause hotkey (#15), settings (#13), the frontmost app / window title source (#17, not yet wired into the app or storage) and the privacy filter that drops excluded apps and sites before storage (#20); no capture is recorded yet. This document is updated with every capture-related change).

| Signal | Stored | Retention | Leaves device |
|---|---|---|---|
| Frontmost app, window title, browser URL (query, fragment and credentials dropped; see [Privacy filter](#privacy-filter)), idle time | Yes (SQLite, local) | User-configurable | Only as text within summarisation input (see below) |
| Webcam frames | **Never stored**; only a yes/no presence flag | Flag kept with timeline | Only aggregated presence totals, as summarisation input; never frames |
| Screenshots | Small thumbnail + OCR text; raw capture deleted after the raw-retention window (default to be set in #27, expected <= 24 h) | Raw: that window; thumbnails and text: user-configurable, default set in #26 | OCR text only, as summarisation input (see below); never the image |
| Summaries | Yes | Configurable | Input text sent to Claude API (configurable, text only) |

Storage: one SQLite file, `~/Library/Application Support/com.lemacarl.unreality/unreality.sqlite`. Every open makes the folder owner-only (0700) and the database, `-wal` and `-shm` files owner-only (0600). SQLite `secure_delete` is on, so deleted pages are zeroed in the database file once checkpointed; the write-ahead log (`unreality.sqlite-wal`) may still hold old page images until it is truncated (automatic PASSIVE checkpoints do not), so the retention deletes run `wal_checkpoint(TRUNCATE)` after purging. Retention deletes only events that ended strictly before the cutoff and never deletes open sessions. The app is not sandboxed: like any non-sandboxed app's files, other processes running as the same macOS user can read the database. Time Machine backups and APFS local snapshots may hold copies that retention and delete-all cannot reach. Schema: [ARCHITECTURE.md](ARCHITECTURE.md#storage).

Settings (#13): non-secret preferences only (idle threshold and retention windows so far, as plain numbers) in the app's UserDefaults domain, `~/Library/Preferences/com.lemacarl.unreality.plist`. They hold no captured data and never secrets (the settings value type does not admit them; the API key stays in the Keychain). The retention values are placeholders: nothing is captured or deleted by them yet.

Defaults: password managers, banking and messaging apps and sites excluded (implemented in #20; list and limits in [Privacy filter](#privacy-filter)); global pause hotkey (Control-Option-Command-P by default; implemented in #15 via Carbon `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring permission and only reports that one combination, never other keystrokes. If another app or a system shortcut holds the same combination, macOS does not tell Unreality, and pressing it may do nothing; always check the menu-bar icon, which is the source of truth for whether capture is paused); visible capture indicator; API key stored in the macOS Keychain only (implemented in #14: login keychain, not iCloud-synchronised, never logged; see ARCHITECTURE.md, "Secrets").

## Frontmost app and window titles (#17)
What is read, on the Mac, by `WorkspaceActivitySource`:

- **Frontmost app**: bundle ID (for example `com.apple.finder`), localised app name and process ID, from `NSWorkspace` app-activation notifications. Needs no permission. The process ID is never meant to be stored.
- **Focused window title** of the frontmost app only, through the Accessibility API (`AXUIElement`): the app's focused-window attribute (a reference to the window) is queried, then that window's title attribute. Needs the **Accessibility** permission (System Settings > Privacy & Security > Accessibility). Window titles can contain sensitive text: document and file names, email subjects, chat contact names, web page titles, sometimes account names. Nothing else is read: no window contents, keystrokes or other UI elements. Unreality's own windows are excluded: no Accessibility call targets Unreality's own process, and its samples are app-only. Titles are also never read for a process without a bundle ID, because no exclusion list could match it.

When it is read: once when tracking starts or resumes, on every app switch, and when the frontmost app's focused window or its title changes (notifications, no polling). Nothing is read while capture is paused: the coordinator stops the source on pause and drops anything that still arrives.

Permission: Unreality checks whether it has Accessibility access without prompting (`AXIsProcessTrusted`) and exposes that state; the system prompt is shown only when the user asks for it (`requestAccess()`, for a future onboarding/settings button), never silently at launch. Without the permission, samples are app-only (no titles; nothing is recorded yet). Revoking it takes effect at the next app switch or title change. After granting it, titles start at the next app switch, or immediately when the app re-checks the permission (`refreshAccessibilityTrust()`, for example when it becomes active again).

Before a title is read, the privacy filter is asked whether that app's titles may be read at all, so excluded apps' titles are never read. This is per app: excluding a site or a private window inside a browser can only drop or redact the sample after its title was read into memory (#19, #20), before anything is stored. That filter is #20: until it lands, samples are not stored or shown anywhere (the source is not yet wired into the app).

## What leaves the device
Only text built from the signals above (app/window titles, redacted URLs, OCR text, active/idle totals, presence totals) is sent to the Claude API for summaries, only after the user enables it and supplies a key. Images, webcam frames and excluded-app data are never sent. Excluded apps/sites are filtered before storage; screen capture must use ScreenCaptureKit app/window exclusion so excluded windows are not captured even when visible behind another app (tracked in #23).

## Privacy filter
`PrivacyFilter` (UnrealityCore, #20) sits between capture and storage. Every captured sample passes through it; storage accepts only its output.

**Guarantee.** The repository's only insert takes a `FilteredEvent`, a type that only `PrivacyFilter` can create (its initialiser is private to the filter's file and it is not `Decodable`); the stored-event type `ActivityEvent` cannot be inserted. So a sample from an excluded app or site produces no row, and no URL is stored unredacted, by construction rather than by convention. Unit tests feed fixture samples from excluded apps and sites through the filter into a recording repository, an in-memory database and a database file, and check that none of them (nor a sentinel in their titles) is stored or written to disk.

**What it does to each sample:**
- **Excluded app** (frontmost app's bundle ID on the blocklist): dropped entirely.
- **Excluded site** (URL host, or a parent domain of it, on the blocklist): dropped entirely, including the window title.
- **URL that cannot be checked** (unparseable, no scheme, an `http(s)` URL without a host, or a web sample without a URL): dropped entirely. The filter fails closed rather than store a title it could not attribute.
- **Other URLs:** `http(s)` URLs keep only `scheme://host[:port]/path`. The query, fragment, `user:password@` credentials and `;` path parameters (such as `;jsessionid=`) are dropped, rather than the whole URL being blanked; the host is lowercased. A stricter mode (`hostOnly`) also drops the path. Other schemes (`file:`, `data:`, `about:`, browser-extension pages) keep only the scheme, since they carry local paths or content rather than a site.
- **Idle samples:** stored without app, title or URL.

**Blocklist.** Matching is case-insensitive. A bundle ID entry matches exactly or, ending in `.*`, the prefix and everything under it (`com.example.*`). A domain entry matches that host and all its subdomains (`example.com` matches `www.example.com`, not `notexample.com`); a scheme, path, port, `*.` or leading dot in an entry is ignored. User entries extend the defaults (`Blocklist.defaults.union(user)`); the settings UI that collects and persists them, and lets users remove a default, comes in M6.

**Limits.** The filter only sees what capture sources report about the frontmost app and its active tab:
- An excluded site is recognised only from the URL of the frontmost browser window's active tab. The same site in a background tab, another window, a non-browser app (an embedded web view, a mail preview) or only in a window title is not recognised.
- Window titles of allowed apps are stored as they are and may mention excluded services (for example a mail subject from a bank). Titles are not matched against the blocklist.
- Defaults are best effort. Bundle IDs change between app versions and new apps appear. Banking is mostly done in the browser, so the defaults cover only a few large banks and payment services by domain, and no banking apps: add your own bank's app and site.
- The filter decides what is stored, not what is captured. Screenshots of excluded windows must be avoided at capture time with ScreenCaptureKit exclusion (#23).
- Adding an entry does not remove data stored before it was added.

**Logging.** Window titles and URLs are never logged. `ActivitySample`, `FilteredEvent` and `ActivityEvent` redact the title and URL in `description`, `debugDescription`, string interpolation and `dump`, so logging one by mistake does not leak them. GRDB's `publicStatementArguments` stays off (set explicitly; a test checks that a database error does not contain the inserted title), so SQLite error messages never carry stored values.

### Default exclusions
Source of truth: `DefaultExclusions` in `Sources/UnrealityCore/Privacy/Blocklist.swift`; keep this table in sync.

| Category | Apps (bundle ID patterns) | Sites (domains, with subdomains) |
|---|---|---|
| Password managers | `com.1password.*` (1Password 8), `com.agilebits.*` (1Password 7 and earlier), `com.bitwarden.*`, `com.lastpass.*`, `org.keepassxc.*`, `in.sinew.*` (Enpass), `com.apple.keychainaccess` (Keychain Access), `com.apple.Passwords` (Passwords) | `1password.com`, `1password.eu`, `1password.ca`, `bitwarden.com`, `bitwarden.eu`, `lastpass.com`, `passwords.google.com` |
| Messaging | `com.apple.MobileSMS` (Messages), `com.apple.FaceTime`, `net.whatsapp.*`, `org.whispersystems.signal-desktop` (Signal), `ru.keepcoder.Telegram` (Telegram for macOS), `com.tdesktop.Telegram` (Telegram Desktop), `com.facebook.archon.*` (Messenger), `com.hnc.Discord` | `web.whatsapp.com`, `web.telegram.org`, `messenger.com`, `messages.google.com`, `discord.com` |
| Banking and payments | none (add your bank's app) | `paypal.com`, `wise.com`, `revolut.com`, `chase.com`, `bankofamerica.com`, `wellsfargo.com`, `citi.com`, `capitalone.com`, `hsbc.com`, `barclays.co.uk` |

Work chat (Slack, Microsoft Teams) is not excluded by default, since it is usually part of the work being logged; add it to exclude it.
