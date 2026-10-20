/// A global keyboard shortcut: a virtual key code plus modifiers. Identity
/// (equality and hashing) is the key code and modifiers only; `keyLabel` is
/// display text, so every registrar treats two hotkeys alike when the
/// system would.
public struct Hotkey: Sendable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Self(rawValue: 1 << 0)
        public static let option = Self(rawValue: 1 << 1)
        public static let control = Self(rawValue: 1 << 2)
        public static let shift = Self(rawValue: 1 << 3)
    }

    /// macOS virtual key code (`kVK_*` in Carbon's `Events.h`). It names a
    /// physical key position, not a character: on non-QWERTY layouts the key
    /// at that position may carry a different letter than `keyLabel`.
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// Key name for display, e.g. "P" (as printed on a QWERTY keyboard).
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    /// Default global pause/resume shortcut: Control-Option-Command-P
    /// (key code 35, `kVK_ANSI_P`: the key labelled P on a QWERTY layout).
    /// Three modifiers make clashes with other apps unlikely. Override it by passing another `Hotkey` to
    /// `PauseHotkeyController` (a settings UI comes later).
    public static let defaultPause = Hotkey(keyCode: 35, modifiers: [.control, .option, .command], keyLabel: "P")
}

public enum HotkeyError: Error, Equatable {
    /// The system refused the registration; `status` is the OS error code.
    /// The cause is not reported reliably, so callers should not guess it.
    case unavailable(Hotkey, status: Int32)
}

/// Registers system-wide hotkeys. Implementations must see only the
/// registered combinations, never other keystrokes.
@MainActor
public protocol HotkeyRegistrar: AnyObject, Sendable {
    /// Registers `hotkey`, replacing any earlier registration of the same
    /// combination; `action` runs on the main actor on each press.
    func register(_ hotkey: Hotkey, action: @escaping @MainActor () -> Void) throws
    /// Removes `hotkey`. No-op when it is not registered.
    func unregister(_ hotkey: Hotkey)
}

/// Test double for `HotkeyRegistrar`; `press(_:)` simulates the user.
@MainActor
public final class FakeHotkeyRegistrar: HotkeyRegistrar {
    private var actions: [Hotkey: @MainActor () -> Void] = [:]
    /// When set, `register` throws it.
    public var failure: HotkeyError?

    public init() {}

    public var registered: Set<Hotkey> { Set(actions.keys) }

    public func register(_ hotkey: Hotkey, action: @escaping @MainActor () -> Void) throws {
        if let failure { throw failure }
        actions[hotkey] = action
    }

    public func unregister(_ hotkey: Hotkey) {
        actions[hotkey] = nil
    }

    /// Runs the action bound to `hotkey`; returns false if none is registered.
    @discardableResult
    public func press(_ hotkey: Hotkey) -> Bool {
        guard let action = actions[hotkey] else { return false }
        action()
        return true
    }
}

/// Binds the global pause hotkey to `CaptureStateStore.toggle()`. The
/// hotkey is unregistered by `stop()` or when the controller is released
/// (which must happen on the main thread).
@MainActor
public final class PauseHotkeyController {
    public let hotkey: Hotkey
    public private(set) var isActive = false
    private let store: CaptureStateStore
    private let registrar: any HotkeyRegistrar

    public init(store: CaptureStateStore, registrar: any HotkeyRegistrar, hotkey: Hotkey = .defaultPause) {
        self.store = store
        self.registrar = registrar
        self.hotkey = hotkey
    }

    /// Registers the hotkey. Throws `HotkeyError` if the system refuses it.
    public func activate() throws {
        guard !isActive else { return }
        try registrar.register(hotkey) { [weak store] in store?.toggle() }
        isActive = true
    }

    /// Unregisters the hotkey. No-op when not active.
    public func stop() {
        guard isActive else { return }
        registrar.unregister(hotkey)
        isActive = false
    }

    deinit {
        guard isActive else { return }
        let registrar = registrar
        let hotkey = hotkey
        MainActor.assumeIsolated { registrar.unregister(hotkey) }
    }
}
