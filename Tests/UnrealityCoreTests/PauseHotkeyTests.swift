import Testing
import UnrealityCore

@MainActor
@Suite("Pause hotkey")
struct PauseHotkeyTests {
    @Test("default is Control-Option-Command-P")
    func defaultHotkey() {
        #expect(Hotkey.defaultPause.keyCode == 35)
        #expect(Hotkey.defaultPause.modifiers == [.control, .option, .command])
    }

    @Test("pressing the hotkey toggles capture state")
    func pressTogglesState() throws {
        let store = CaptureStateStore()
        let registrar = FakeHotkeyRegistrar()
        let controller = PauseHotkeyController(store: store, registrar: registrar)
        try controller.activate()
        #expect(registrar.registered == [.defaultPause])
        #expect(registrar.press(.defaultPause))
        #expect(store.state == .paused)
        registrar.press(.defaultPause)
        #expect(store.state == .running)
    }

    @Test("a hotkey overridden in code is the one registered")
    func customHotkey() throws {
        let custom = Hotkey(keyCode: 0, modifiers: [.command, .shift], keyLabel: "A")
        let registrar = FakeHotkeyRegistrar()
        let store = CaptureStateStore()
        let controller = PauseHotkeyController(store: store, registrar: registrar, hotkey: custom)
        try controller.activate()
        #expect(registrar.registered == [custom])
        #expect(!registrar.press(.defaultPause))
        registrar.press(custom)
        #expect(store.isPaused)
        withExtendedLifetime(controller) {}
    }

    @Test("hotkey identity ignores the display label")
    func identityIgnoresLabel() throws {
        let relabelled = Hotkey(keyCode: 35, modifiers: [.control, .option, .command], keyLabel: "L")
        #expect(relabelled == .defaultPause)
        #expect(Set([relabelled, .defaultPause]).count == 1)
        let registrar = FakeHotkeyRegistrar()
        try registrar.register(.defaultPause) {}
        registrar.unregister(relabelled)
        #expect(registrar.registered.isEmpty)
    }

    @Test("releasing an active controller unregisters the hotkey")
    func deinitUnregisters() throws {
        let registrar = FakeHotkeyRegistrar()
        var controller: PauseHotkeyController? = PauseHotkeyController(store: CaptureStateStore(), registrar: registrar)
        try controller?.activate()
        #expect(registrar.registered == [.defaultPause])
        controller = nil
        #expect(registrar.registered.isEmpty)
    }

    @Test("stop unregisters, so presses do nothing")
    func stop() throws {
        let store = CaptureStateStore()
        let registrar = FakeHotkeyRegistrar()
        let controller = PauseHotkeyController(store: store, registrar: registrar)
        try controller.activate()
        controller.stop()
        #expect(!controller.isActive)
        #expect(!registrar.press(.defaultPause))
        #expect(store.state == .running)
    }

    @Test("a refused registration throws and leaves the controller inactive")
    func registrationFailure() {
        let registrar = FakeHotkeyRegistrar()
        registrar.failure = .unavailable(.defaultPause, status: -9_878)
        let controller = PauseHotkeyController(store: CaptureStateStore(), registrar: registrar)
        #expect(throws: HotkeyError.unavailable(.defaultPause, status: -9_878)) { try controller.activate() }
        #expect(!controller.isActive)
    }
}
