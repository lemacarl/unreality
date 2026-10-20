import Observation

/// Whether Unreality is currently allowed to capture.
public enum CaptureState: String, Sendable, Equatable, CaseIterable {
    /// Capture is allowed (no capture exists yet; it arrives with M3).
    case running
    /// The user has paused capture; nothing may be recorded.
    case paused

    /// The state `CaptureStateStore.toggle()` moves to from this one.
    public var toggled: Self {
        switch self {
        case .running: .paused
        case .paused: .running
        }
    }
}

/// Single source of truth for the capture running/paused state.
///
/// Observable (Observation framework) so the menu-bar UI redraws on change.
/// The menu-bar popover, the global pause hotkey (#15) and, later, the
/// capture pipeline all read and drive this one store. It holds state only:
/// it starts or stops nothing itself. Not persisted across launches.
///
/// Main-actor isolated: every caller (SwiftUI, the hotkey handler) runs on
/// the main thread, which keeps reads and writes race-free.
@MainActor
@Observable
public final class CaptureStateStore {
    /// Current state. Change it through `pause()`, `resume()` or `toggle()`.
    public private(set) var state: CaptureState
    @ObservationIgnored private var changeHandlers: [Int: @MainActor (CaptureState) -> Void] = [:]
    @ObservationIgnored private var lastHandlerID = 0

    /// Convenience for UI.
    public var isPaused: Bool { state == .paused }

    /// - Parameter initialState: state at launch; defaults to `.running`.
    public init(initialState: CaptureState = .running) {
        state = initialState
    }

    /// Pauses capture. No-op when already paused.
    public func pause() {
        transition(to: .paused)
    }

    /// Resumes capture. No-op when already running.
    public func resume() {
        transition(to: .running)
    }

    /// Flips between running and paused (used by the pause hotkey, #15).
    public func toggle() {
        transition(to: state.toggled)
    }

    /// Calls `handler` synchronously, on the main actor, after every state
    /// change, until the returned subscription is cancelled.
    /// For non-UI code (the activity coordinator) that must react to a pause
    /// before anything else is recorded; SwiftUI uses Observation instead.
    public func onChange(_ handler: @escaping @MainActor (CaptureState) -> Void) -> CaptureStateSubscription {
        lastHandlerID += 1
        let id = lastHandlerID
        changeHandlers[id] = handler
        return CaptureStateSubscription { [weak self] in self?.changeHandlers[id] = nil }
    }

    private func transition(to newState: CaptureState) {
        // Skip same-value writes so observers are not invalidated needlessly.
        guard state != newState else { return }
        state = newState
        for id in changeHandlers.keys.sorted() {
            changeHandlers[id]?(newState)
        }
    }
}

/// Handle returned by `CaptureStateStore.onChange(_:)`. Cancelling twice is
/// harmless. Releasing the handle does not cancel (it may be released off
/// the main thread), so owners call `cancel()` when they are done.
@MainActor
public final class CaptureStateSubscription {
    private var onCancel: (@MainActor () -> Void)?

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}
