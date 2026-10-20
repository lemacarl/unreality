import SwiftUI
import UnrealityCore

/// Menu-bar-only app shell (LSUIElement: no Dock icon, no main window).
/// The status item's icon reflects `CaptureStateStore`; clicking it opens a
/// popover with the state, a pause/resume control, Settings and Quit; the
/// Settings scene is the settings window. State lives in
/// `AppModel`, owned by `AppDelegate`, so the global hotkey reaches it too.
@main
struct UnrealityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let captureState = appDelegate.model.captureState
        MenuBarExtra {
            StatusPopover(model: appDelegate.model)
        } label: {
            // Template SF Symbol: macOS tints it for light/dark menu bars.
            Image(systemName: captureState.state.symbolName)
                .accessibilityLabel("\(AppIdentity.displayName): \(captureState.state.title)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
