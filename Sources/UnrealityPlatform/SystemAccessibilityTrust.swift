import ApplicationServices
import UnrealityCore

/// `AccessibilityTrust` backed by `AXIsProcessTrusted`. `currentState()`
/// never prompts; only `requestAccess()` shows the system prompt.
///
/// macOS ties the grant to the app's bundle ID and code signature, so an
/// ad-hoc build may lose it on every rebuild (CONTRIBUTING.md, "Local
/// development"). When run from `swift test`, the grant that counts is the
/// one of the app that launched the tests (for example the terminal).
@MainActor
public final class SystemAccessibilityTrust: AccessibilityTrust {
    public init() {}

    public func currentState() -> AccessibilityTrustState {
        AXIsProcessTrusted() ? .trusted : .notTrusted
    }

    @discardableResult
    public func requestAccess() -> AccessibilityTrustState {
        // The string value of `kAXTrustedCheckOptionPrompt`; the global itself
        // is a mutable C variable that Swift 6 rejects as not concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .trusted : .notTrusted
    }
}
