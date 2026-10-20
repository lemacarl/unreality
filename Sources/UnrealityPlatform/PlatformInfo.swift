import Foundation

/// Placeholder for the platform layer so the target is non-empty. Real
/// implementations of the UnrealityCore protocols (ActivitySource,
/// ScreenCapturer, ...) land here with their feature issues, each behind a
/// protocol declared in the core with a fake for tests; this static
/// ProcessInfo read is not the template for them.
public enum PlatformInfo {
    /// Running macOS version, e.g. "14.5.0".
    public static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
