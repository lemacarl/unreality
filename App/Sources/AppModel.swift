import AppKit
import Observation
import os
import UnrealityCore
import UnrealityPlatform

/// App-wide state and services, owned by `AppDelegate` for the app's
/// lifetime so non-SwiftUI code (the global hotkey handler) can reach the
/// same `CaptureStateStore` as the menu bar.
@MainActor
@Observable
final class AppModel {
    let captureState = CaptureStateStore()
    let pauseHotkeyController: PauseHotkeyController
    /// True when the system refused to register the pause hotkey.
    private(set) var isPauseHotkeyUnavailable = false
    @ObservationIgnored private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")

    /// - Parameter pauseHotkey: override the default pause shortcut here
    ///   until the settings UI (#13) can change it.
    init(
        pauseHotkey: Hotkey = .defaultPause,
        hotkeys: any HotkeyRegistrar = CarbonHotkeyRegistrar()
    ) {
        pauseHotkeyController = PauseHotkeyController(store: captureState, registrar: hotkeys, hotkey: pauseHotkey)
    }

    func start() {
        do {
            try pauseHotkeyController.activate()
        } catch {
            isPauseHotkeyUnavailable = true
            logger.error("Pause hotkey registration failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Owns the `AppModel` and starts its services once the app has launched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }
}
