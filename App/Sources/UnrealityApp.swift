import SwiftUI
import UnrealityCore
import UnrealityPlatform

/// Menu-bar-only app shell (LSUIElement: no Dock icon, no main window).
/// Features are wired in by later issues.
@main
struct UnrealityApp: App {
    var body: some Scene {
        MenuBarExtra(AppIdentity.displayName, systemImage: "eye") {
            Text("\(AppIdentity.displayName) — not recording yet")
            Text("macOS \(PlatformInfo.operatingSystemVersion)")
            Divider()
            Button("Quit \(AppIdentity.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
