/// Whether macOS lets this app use the Accessibility API (needed to read
/// window titles). Without it, activity degrades to app-only samples.
public enum AccessibilityTrustState: String, Sendable, Equatable, CaseIterable {
    case trusted
    case notTrusted
}

/// Reads, and on explicit request asks for, the Accessibility permission.
@MainActor
public protocol AccessibilityTrust: AnyObject {
    /// The current state. Must never show a system prompt.
    func currentState() -> AccessibilityTrustState

    /// Shows the system prompt that points the user to System Settings. Call
    /// it only from an explicit user action (for example a "Grant access"
    /// button), never at launch or in the background. Returns the state at
    /// the time of the call; the user grants access later, in System Settings.
    @discardableResult
    func requestAccess() -> AccessibilityTrustState
}

/// Test double for `AccessibilityTrust`.
@MainActor
public final class FakeAccessibilityTrust: AccessibilityTrust {
    public var state: AccessibilityTrustState
    /// How many times `requestAccess()` was called (the prompt was shown).
    public private(set) var requestCount = 0

    public init(state: AccessibilityTrustState = .notTrusted) {
        self.state = state
    }

    public func currentState() -> AccessibilityTrustState { state }

    @discardableResult
    public func requestAccess() -> AccessibilityTrustState {
        requestCount += 1
        return state
    }
}
