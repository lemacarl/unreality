import AppKit
import SwiftUI
import UnrealityCore
import UnrealityPlatform

/// Popover shown from the menu-bar status item.
struct StatusPopover: View {
    let store: CaptureStateStore

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

            Divider()

            HStack {
                Text("macOS \(PlatformInfo.operatingSystemVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit \(AppIdentity.displayName)") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 280)
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
