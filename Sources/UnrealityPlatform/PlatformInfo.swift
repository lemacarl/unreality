import Foundation
import UnrealityCore

/// Placeholder for the platform layer. Real implementations of the
/// UnrealityCore protocols (ActivitySource, ScreenCapturer, ...) land here
/// with their feature issues.
public enum PlatformInfo {
    /// Running macOS version, e.g. "14.5.0".
    public static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Display name re-exported from the core so the app shell has one source of truth.
    public static var appDisplayName: String {
        AppIdentity.displayName
    }
}
