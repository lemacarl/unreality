# Unreality

A private, local-first macOS app that records what you work on and turns it into honest, useful summaries.

**Status:** pre-alpha, bootstrapping. See [docs/ROADMAP.md](docs/ROADMAP.md).

Unreality combines activity tracking, on-device presence verification, on-device screen OCR, and AI-written hourly/daily summaries. All data stays on your Mac; only text you configure for summarisation goes to the Claude API. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Build and run
Requirements: macOS 14 or later, Xcode 26 (Swift 6.2 toolchain), XcodeGen and SwiftLint. `brew install xcodegen swiftlint` installs the latest versions, not the pinned ones; check `xcodegen --version` and `swiftlint version` against the table in [CONTRIBUTING.md](CONTRIBUTING.md#tool-versions).

```sh
# Core and platform packages
swift build
swift test

# App shell (the Xcode project is generated from project.yml and gitignored)
xcodegen generate
xcodebuild -scheme Unreality -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# Lint (warnings fail)
swiftlint --strict
```

To run the app, open the generated `Unreality.xcodeproj` in Xcode and run the `Unreality` scheme, or build with signing enabled (drop `CODE_SIGNING_ALLOWED=NO`; the project signs ad hoc by default, see `Config/Signing.xcconfig`) and launch the `.app` from the build products. It is menu-bar only: look for the eye icon in the menu bar; there is no Dock icon or window. `CODE_SIGNING_ALLOWED=NO` builds are for compiling/CI only and may not launch.

### Permissions
The current shell requests no permissions. As features land, Unreality will ask for:

- **Screen Recording** (screenshots and on-device OCR)
- **Camera** (on-device presence detection; frames are never stored)
- **Accessibility** (frontmost window titles and browser URLs)
- possibly **Automation** (Apple Events), depending on how browser URLs end up being read

The Claude API key you supply is stored in the Keychain. That needs no permission grant, but macOS may ask to allow access if the app's signing identity changes (for example between ad-hoc builds).

Grants are tied to the bundle ID `com.lemacarl.unreality` and the signing identity; see [CONTRIBUTING.md](CONTRIBUTING.md#local-development) for keeping them across rebuilds.
