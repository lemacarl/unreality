import SwiftUI
import UnrealityCore

/// Menu-bar-only app shell (LSUIElement: no Dock icon, no main window).
/// The status item's icon reflects `CaptureStateStore`; clicking it opens a
/// popover with the state, a pause/resume control and Quit.
@main
struct UnrealityApp: App {
    @State private var captureState = CaptureStateStore()

    var body: some Scene {
        MenuBarExtra {
            StatusPopover(store: captureState)
        } label: {
            // Template SF Symbol: macOS tints it for light/dark menu bars.
            Image(systemName: captureState.state.symbolName)
                .accessibilityLabel("\(AppIdentity.displayName): \(captureState.state.title)")
        }
        .menuBarExtraStyle(.window)
    }
}
