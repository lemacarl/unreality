import Carbon.HIToolbox
import UnrealityCore

/// `HotkeyRegistrar` backed by Carbon `RegisterEventHotKey` (ADR 0001).
/// It needs no Accessibility or Input Monitoring permission, and the app is
/// told only about its own registered combinations, never other keystrokes.
///
/// Owned for the app's lifetime by the app model; `deinit` removes the
/// registrations and the event handler, so the registrar must be released
/// on the main thread (as it is when its main-actor owner releases it).
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private struct Registration {
        let hotkey: Hotkey
        let ref: EventHotKeyRef
        let action: @MainActor () -> Void
    }

    /// Four-char code "UNRE" tagging this app's hotkey IDs.
    private static let signature: OSType = 0x554E_5245
    // `nonisolated(unsafe)` only so `deinit` can release them: every other
    // access is main-actor isolated, and deinit has exclusive access.
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    nonisolated(unsafe) private var registrations: [UInt32: Registration] = [:]
    private var lastID: UInt32 = 0

    public init() {}

    deinit {
        registrations.values.forEach { UnregisterEventHotKey($0.ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    public func register(_ hotkey: Hotkey, action: @escaping @MainActor () -> Void) throws {
        unregister(hotkey)
        try installHandlerIfNeeded(for: hotkey)
        lastID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            Self.carbonModifiers(hotkey.modifiers),
            EventHotKeyID(signature: Self.signature, id: lastID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { throw HotkeyError.unavailable(hotkey, status: status) }
        registrations[lastID] = Registration(hotkey: hotkey, ref: ref, action: action)
    }

    public func unregister(_ hotkey: Hotkey) {
        for (id, registration) in registrations where registration.hotkey == hotkey {
            UnregisterEventHotKey(registration.ref)
            registrations[id] = nil
        }
    }

    private func installHandlerIfNeeded(for hotkey: Hotkey) throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else { throw HotkeyError.unavailable(hotkey, status: status) }
    }

    fileprivate func handlePress(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature, let registration = registrations[id.id] else {
            return OSStatus(eventNotHandledErr)
        }
        registration.action()
        return noErr
    }

    private static func carbonModifiers(_ modifiers: Hotkey.Modifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}

/// C callback for hotkey-pressed events; `userData` is the registrar.
private func hotkeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return status }
    // Handlers on the application event target run on the main thread.
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { registrar.handlePress(id) }
}
