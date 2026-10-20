# Privacy

Target behaviour (implemented so far: Keychain storage of the API key (#14), local SQLite storage (#16), the global pause hotkey (#15) and settings (#13); no capture yet. This document is updated with every capture-related change).

| Signal | Stored | Retention | Leaves device |
|---|---|---|---|
| Frontmost app, window title, browser URL (query strings redacted by default), idle time | Yes (SQLite, local) | User-configurable | Only as text within summarisation input (see below) |
| Webcam frames | **Never stored**; only a yes/no presence flag | Flag kept with timeline | Only aggregated presence totals, as summarisation input; never frames |
| Screenshots | Small thumbnail + OCR text; raw capture deleted after the raw-retention window (default to be set in #27, expected <= 24 h) | Raw: that window; thumbnails and text: user-configurable, default set in #26 | OCR text only, as summarisation input (see below); never the image |
| Summaries | Yes | Configurable | Input text sent to Claude API (configurable, text only) |

Storage: one SQLite file, `~/Library/Application Support/com.lemacarl.unreality/unreality.sqlite`. Every open makes the folder owner-only (0700) and the database, `-wal` and `-shm` files owner-only (0600). SQLite `secure_delete` is on, so deleted pages are zeroed in the database file once checkpointed; the write-ahead log (`unreality.sqlite-wal`) may still hold old page images until it is truncated (automatic PASSIVE checkpoints do not), so the retention deletes run `wal_checkpoint(TRUNCATE)` after purging. Retention deletes only events that ended strictly before the cutoff and never deletes open sessions. The app is not sandboxed: like any non-sandboxed app's files, other processes running as the same macOS user can read the database. Time Machine backups and APFS local snapshots may hold copies that retention and delete-all cannot reach. Schema: [ARCHITECTURE.md](ARCHITECTURE.md#storage).

Settings (#13): non-secret preferences only (idle threshold and retention windows so far, as plain numbers) in the app's UserDefaults domain, `~/Library/Preferences/com.lemacarl.unreality.plist`. They hold no captured data and never secrets (the settings value type does not admit them; the API key stays in the Keychain). The retention values are placeholders: nothing is captured or deleted by them yet.

Defaults: password managers, banking and messaging apps excluded; global pause hotkey (Control-Option-Command-P by default; implemented in #15 via Carbon `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring permission and only reports that one combination, never other keystrokes. If another app or a system shortcut holds the same combination, macOS does not tell Unreality, and pressing it may do nothing; always check the menu-bar icon, which is the source of truth for whether capture is paused); visible capture indicator; API key stored in the macOS Keychain only (implemented in #14: login keychain, not iCloud-synchronised, never logged; see ARCHITECTURE.md, "Secrets").

## What leaves the device
Only text built from the signals above (app/window titles, redacted URLs, OCR text, active/idle totals, presence totals) is sent to the Claude API for summaries, only after the user enables it and supplies a key. Images, webcam frames and excluded-app data are never sent. Excluded apps/sites are filtered before storage; screen capture must use ScreenCaptureKit app/window exclusion so excluded windows are not captured even when visible behind another app (tracked in #23).
