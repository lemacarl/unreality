# Architecture

Stack: native Swift ([ADR 0001](decisions/0001-technology-stack.md)). Status: design only; no code yet.

```mermaid
flowchart LR
  subgraph Platform[UnrealityPlatform - real OS integrations]
    A[ActivitySource] --- S[ScreenCapturer + OCRService] --- F[FaceDetector] --- K[KeychainStore] --- C[AIClient impl]
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

## Data flow
Platform sources emit samples → privacy filter drops excluded apps/sites (before capture or OCR where possible, always before storage) → dedupe skips unchanged screens → events/OCR text/presence booleans written to SQLite → retention job deletes raw captures after the window → summariser sends text only to the Claude API.

## Storage schema, threading model
To be filled in by the M2 storage issue. Threading: capture on background actors, DB access serialised via GRDB, UI on the main actor.
