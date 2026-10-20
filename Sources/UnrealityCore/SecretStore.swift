import Foundation

/// Names one secret in a ``SecretStore``, e.g. the Claude API key.
///
/// The raw value is the item's account name inside the store's namespace
/// (for the Keychain implementation, the `kSecAttrAccount` within its
/// service). It is an identifier, not a secret, and is safe to log.
public struct SecretKey: Hashable, Sendable, CustomStringConvertible {
    /// Account name of the secret. Never empty.
    public let rawValue: String

    /// Creates a key. Returns `nil` for an empty or whitespace-only name.
    public init?(_ rawValue: String) {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.rawValue = rawValue
    }

    /// The user's Claude API key (entered in the settings UI, M5).
    public static let claudeAPIKey = SecretKey(unchecked: "claude-api-key")

    public var description: String { rawValue }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A secret value whose textual representations are redacted.
///
/// `print(secret)`, string interpolation, `dump` and debugger summaries all
/// show `<redacted>`, so a secret passed to a logger by mistake does not
/// leak. Read the plaintext only through ``reveal()`` at the point of use
/// (for example when building an HTTP header), and never log that.
public struct SecretValue: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let plaintext: String

    /// Wraps `plaintext`. Returns `nil` for an empty string: an empty secret
    /// is never valid and storing one would hide a bug.
    public init?(_ plaintext: String) {
        guard !plaintext.isEmpty else { return nil }
        self.plaintext = plaintext
    }

    /// The plaintext secret. Do not log, print or persist it outside a
    /// ``SecretStore``.
    public func reveal() -> String { plaintext }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "SecretValue(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Errors thrown by a ``SecretStore``. They never carry secret values, so
/// they are safe to log.
public enum SecretStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The store holds bytes for the key that are not a valid UTF-8,
    /// non-empty secret.
    case corruptItem(SecretKey)
    /// The store refused access (user denied the prompt or authentication
    /// failed).
    case accessDenied(SecretKey)
    /// The store cannot be used without user interaction right now (for
    /// example the keychain is locked).
    case interactionNotAllowed(SecretKey)
    /// Any other failure, with the underlying status code (an `OSStatus`
    /// for the Keychain implementation).
    case unexpectedStatus(Int32, SecretKey)

    public var description: String {
        switch self {
        case let .corruptItem(key):
            "Stored secret '\(key)' is unreadable"
        case let .accessDenied(key):
            "Access to secret '\(key)' was denied"
        case let .interactionNotAllowed(key):
            "Secret '\(key)' is unavailable without user interaction (store locked?)"
        case let .unexpectedStatus(status, key):
            "Secret store failed for '\(key)' with status \(status)"
        }
    }
}

/// Stores small secrets such as the Claude API key.
///
/// The real implementation is `KeychainSecretStore` in UnrealityPlatform;
/// tests and previews use ``InMemorySecretStore``. Secrets must never live
/// anywhere else (no UserDefaults, files or database), and implementations
/// must never log secret values.
///
/// Contract, checked against the fake by `SecretStoreContractTests`:
/// - ``secret(for:)`` returns `nil` when no secret is stored for the key.
/// - ``setSecret(_:for:)`` inserts or replaces the value for the key.
/// - ``removeSecret(for:)`` deletes the value; removing a missing key
///   succeeds (idempotent).
/// - Keys are independent of each other.
public protocol SecretStore: Sendable {
    /// The stored secret for `key`, or `nil` if there is none.
    func secret(for key: SecretKey) throws(SecretStoreError) -> SecretValue?

    /// Stores `value` for `key`, replacing any existing value.
    func setSecret(_ value: SecretValue, for key: SecretKey) throws(SecretStoreError)

    /// Deletes the secret for `key`. Succeeds if there is none.
    func removeSecret(for key: SecretKey) throws(SecretStoreError)
}

/// In-memory ``SecretStore`` for tests and previews. Nothing is persisted.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`. (`Mutex` from
    // Synchronization needs macOS 15; the deployment target is 14.)
    private let lock = NSLock()
    private var storage: [SecretKey: SecretValue]

    /// Creates a store pre-populated with `secrets`.
    public init(_ secrets: [SecretKey: SecretValue] = [:]) {
        storage = secrets
    }

    public func secret(for key: SecretKey) throws(SecretStoreError) -> SecretValue? {
        lock.withLock { storage[key] }
    }

    public func setSecret(_ value: SecretValue, for key: SecretKey) throws(SecretStoreError) {
        lock.withLock { storage[key] = value }
    }

    public func removeSecret(for key: SecretKey) throws(SecretStoreError) {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }
}
