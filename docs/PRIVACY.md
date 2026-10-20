# Privacy

Target behaviour (nothing is implemented yet; this document is updated with every capture-related change).

| Signal | Stored | Retention | Leaves device |
|---|---|---|---|
| Frontmost app, window title, browser URL, idle time | Yes (SQLite, local) | User-configurable | No |
| Webcam frames | **Never stored**; only a yes/no presence flag | Flag kept with timeline | No |
| Screenshots | Small thumbnail + OCR text; raw capture deleted after a short window | Raw: short; text: configurable | No |
| Summaries | Yes | Configurable | Input text sent to Claude API (configurable, text only) |

Defaults: password managers, banking and messaging apps excluded; global pause hotkey; visible capture indicator; API key stored in the macOS Keychain only.
