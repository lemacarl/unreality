# Privacy

Target behaviour (nothing is implemented yet; this document is updated with every capture-related change).

| Signal | Stored | Retention | Leaves device |
|---|---|---|---|
| Frontmost app, window title, browser URL (query strings redacted by default), idle time | Yes (SQLite, local) | User-configurable | Only as text within summarisation input (see below) |
| Webcam frames | **Never stored**; only a yes/no presence flag | Flag kept with timeline | Only aggregated presence totals, as summarisation input; never frames |
| Screenshots | Small thumbnail + OCR text; raw capture deleted after the raw-retention window (default to be set in #27, expected <= 24 h) | Raw: that window; thumbnails and text: user-configurable, default set in #26 | OCR text only, as summarisation input (see below); never the image |
| Summaries | Yes | Configurable | Input text sent to Claude API (configurable, text only) |

Defaults: password managers, banking and messaging apps excluded; global pause hotkey; visible capture indicator; API key stored in the macOS Keychain only.

## What leaves the device
Only text built from the signals above (app/window titles, redacted URLs, OCR text, active/idle totals, presence totals) is sent to the Claude API for summaries, only after the user enables it and supplies a key. Images, webcam frames and excluded-app data are never sent. Excluded apps/sites are filtered before storage; screen capture must use ScreenCaptureKit app/window exclusion so excluded windows are not captured even when visible behind another app (tracked in #23).
