import SwiftUI
import UnrealityCore

/// The Settings window (SwiftUI `Settings` scene), opened from the status
/// popover or with Command-comma while the app is active. Sections for later
/// milestones are stubs. Values persist through `SettingsModel`.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettingsTab(settings: model.settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            PrivacySettingsTab(settings: model.settings)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 480)
        .frame(minHeight: 300)
    }
}

private struct GeneralSettingsTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Pause or resume capture") {
                    Text(model.pauseHotkeyController.hotkey.displayString)
                        .font(.body.monospaced())
                        .accessibilityLabel(model.pauseHotkeyController.hotkey.spokenDescription)
                }
                if model.isPauseHotkeyUnavailable {
                    Text("This shortcut could not be registered. Use the menu-bar icon to pause and resume.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("Changing the shortcut is not supported yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettingsTab: View {
    let settings: SettingsModel

    var body: some View {
        Form {
            Section {
                MinutesStepper(
                    title: "Idle after",
                    value: settings.binding(for: AppSettings.idleThresholdMinutes),
                    range: AppSettings.idleThresholdRange
                )
            } header: {
                Text("Idle detection")
            } footer: {
                Text("Placeholder: no idle detection exists yet. It will use this value when it arrives.")
                    .foregroundStyle(.secondary)
            }
            Section("Screen capture") {
                Text("Screen capture and OCR settings arrive in a later milestone.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettingsTab: View {
    let settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: settings.binding(for: AppSettings.rawCaptureRetentionHours),
                    in: AppSettings.rawCaptureRetentionRange
                ) {
                    LabeledContent(
                        "Keep raw screenshots for",
                        value: hours(settings[AppSettings.rawCaptureRetentionHours])
                    )
                }
                Stepper(
                    value: settings.binding(for: AppSettings.contentRetentionDays),
                    in: AppSettings.contentRetentionRange
                ) {
                    LabeledContent(
                        "Keep thumbnails, text and activity for",
                        value: days(settings[AppSettings.contentRetentionDays])
                    )
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Placeholders: nothing is captured or deleted yet. Retention jobs will use these values.")
                    .foregroundStyle(.secondary)
            }
            Section("Excluded apps and sites") {
                Text("The blocklist arrives in a later milestone.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func hours(_ count: Int) -> String { count == 1 ? "1 hour" : "\(count) hours" }
    private func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
}

private struct AISettingsTab: View {
    var body: some View {
        Form {
            Section("Summaries") {
                Text(
                    "AI summaries and the Claude API key arrive in a later milestone. "
                        + "The key will be stored in the Keychain, never in settings."
                )
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MinutesStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            LabeledContent(title, value: value == 1 ? "1 minute" : "\(value) minutes")
        }
    }
}

extension SettingsModel {
    /// A SwiftUI binding that reads and writes `key` through the model.
    func binding<Value>(for key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }
}

extension Hotkey {
    /// VoiceOver text, e.g. "Control Option Command P".
    var spokenDescription: String {
        let names: [(Modifiers, String)] = [
            (.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")
        ]
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [keyLabel]).joined(separator: " ")
    }
}
