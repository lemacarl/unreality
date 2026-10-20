/// Static identity of the app, shared by the core, platform layer and app shell.
///
/// Placeholder domain type for the scaffold; real domain types arrive with
/// their feature issues.
public enum AppIdentity {
    /// User-facing product name.
    public static let displayName = "Unreality"

    /// Stable bundle identifier. Must match `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `project.yml`; changing it makes macOS drop privacy (TCC) grants.
    public static let bundleIdentifier = "com.lemacarl.unreality"
}
