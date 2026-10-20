import AppKit
import SwiftUI
import UnrealityCore
import UnrealityPlatform

/// Popover shown from the menu-bar status item. "Settings…" opens the
/// Settings scene (`SettingsView`).
struct StatusPopover: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    private var store: CaptureStateStore { model.captureState }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: store.state.symbolName)
                    .foregroundStyle(store.isPaused ? Color.secondary : Color.accentColor)
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppIdentity.displayName)
                        .font(.headline)
                    Text(store.state.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Capture is not implemented yet; this only records your choice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                store.toggle()
            } label: {
                Label(store.state.toggleActionTitle, systemImage: store.isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Text(hotkeyCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Settings…") {
                    // A menu-bar-only (LSUIElement) app is not active while
                    // its popover is open; activate it so the window comes
                    // to the front instead of opening behind other apps.
                    NSApplication.shared.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit \(AppIdentity.displayName)") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }

            Text("macOS \(PlatformInfo.operatingSystemVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var hotkeyCaption: String {
        let shortcut = model.pauseHotkeyController.hotkey.displayString
        return model.isPauseHotkeyUnavailable
            ? "Shortcut \(shortcut) could not be registered."
            : "Shortcut: \(shortcut)"
    }
}

extension Hotkey {
    /// Menu-style shortcut text, e.g. "⌃⌥⌘P".
    var displayString: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyLabel
    }
}

/// Presentation of `CaptureState` for the menu bar (UI-only, so it lives in
/// the app shell rather than the core).
extension CaptureState {
    /// SF Symbol for the status item; rendered as a template image.
    var symbolName: String {
        switch self {
        case .running: "eye"
        case .paused: "eye.slash"
        }
    }

    var title: String {
        switch self {
        case .running: "Capture running"
        case .paused: "Capture paused"
        }
    }

    var toggleActionTitle: String {
        switch self {
        case .running: "Pause Capture"
        case .paused: "Resume Capture"
        }
    }
}
