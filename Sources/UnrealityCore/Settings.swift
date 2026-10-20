import Foundation
import Observation

/// A value a ``SettingsStore`` can hold: a property-list primitive.
///
/// Only plain, non-secret types conform. ``SecretValue`` deliberately does
/// not, so a secret cannot be written to settings by mistake; secrets belong
/// in a ``SecretStore``.
public protocol SettingValue: Sendable, Equatable {
    /// Decodes a stored property-list object; `nil` if it has the wrong type.
    init?(propertyListValue: Any)
    /// The property-list object to store.
    var propertyListValue: Any { get }
}

extension Int: SettingValue {
    public init?(propertyListValue: Any) {
        // NSNumber bridging would also turn a stored Bool ("c") or a
        // floating-point number ("f", "d") into an Int; reject those.
        guard let number = propertyListValue as? NSNumber,
              !["c", "f", "d"].contains(String(cString: number.objCType))
        else { return nil }
        self = number.intValue
    }

    public var propertyListValue: Any { NSNumber(value: self) }
}

extension Bool: SettingValue {
    public init?(propertyListValue: Any) {
        guard let number = propertyListValue as? NSNumber, String(cString: number.objCType) == "c" else {
            return nil
        }
        self = number.boolValue
    }

    public var propertyListValue: Any { NSNumber(value: self) }
}

/// Names one setting, its type, default and valid range.
///
/// The `name` is the storage key (for the UserDefaults implementation, the
/// defaults key). Shipped names are never renamed; a rename loses the user's
/// value.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    public let defaultValue: Value
    private let sanitizer: @Sendable (Value) -> Value

    /// - Parameter sanitize: maps an out-of-range stored or written value to
    ///   a valid one (for example by clamping). Defaults to identity.
    public init(_ name: String, default defaultValue: Value, sanitize: @escaping @Sendable (Value) -> Value = { $0 }) {
        self.name = name
        self.defaultValue = defaultValue
        sanitizer = sanitize
    }

    /// `value` made valid for this setting.
    public func sanitize(_ value: Value) -> Value {
        sanitizer(value)
    }

    /// The effective value for a stored property-list object (or `nil` when
    /// nothing is stored): the default when missing or of the wrong type,
    /// otherwise the sanitised value.
    public func resolve(storedObject: Any?) -> Value {
        guard let storedObject, let value = Value(propertyListValue: storedObject) else { return defaultValue }
        return sanitize(value)
    }
}

extension SettingKey where Value == Int {
    /// An integer setting clamped to `range`. `defaultValue` must lie in it.
    public init(_ name: String, default defaultValue: Int, range: ClosedRange<Int>) {
        precondition(range.contains(defaultValue), "Default for \(name) must lie in \(range)")
        self.init(name, default: defaultValue) { min(max($0, range.lowerBound), range.upperBound) }
    }
}

/// User settings that exist so far. Everything here is non-secret,
/// non-captured configuration. Values are placeholders until the features
/// that read them land; see docs/ARCHITECTURE.md, "Settings".
public enum AppSettings {
    /// Minutes without input after which the user counts as idle. Read by
    /// idle detection (#18); not used yet.
    public static let idleThresholdMinutes = SettingKey<Int>(
        "idleThresholdMinutes", default: 5, range: idleThresholdRange
    )
    public static let idleThresholdRange = 1...60

    /// Hours raw screen captures are kept before deletion. Read by the raw
    /// retention job (#27), which sets the final default (expected <= 24 h);
    /// not enforced yet.
    public static let rawCaptureRetentionHours = SettingKey<Int>(
        "rawCaptureRetentionHours", default: 24, range: rawCaptureRetentionRange
    )
    public static let rawCaptureRetentionRange = 1...24

    /// Days thumbnails, OCR text and activity events are kept. Read by the
    /// capture store and retention (#26), which sets the final default; not
    /// enforced yet.
    public static let contentRetentionDays = SettingKey<Int>(
        "contentRetentionDays", default: 30, range: contentRetentionRange
    )
    public static let contentRetentionRange = 1...365

    /// Names of every setting, for stores that must tell settings apart from
    /// other data in the same namespace.
    public static let allNames: Set<String> = [
        idleThresholdMinutes.name,
        rawCaptureRetentionHours.name,
        contentRetentionDays.name
    ]
}

/// Persists user settings (non-secret configuration only).
///
/// The real implementation is `UserDefaultsSettingsStore` in
/// UnrealityPlatform; tests and previews use ``InMemorySettingsStore``.
/// Secrets never go here: use ``SecretStore``.
///
/// Contract, checked by `SettingsStoreContractTests` (fake) and
/// `UserDefaultsSettingsStoreTests` (real):
/// - ``value(for:)`` returns the key's default when nothing (or a value of
///   the wrong type) is stored.
/// - ``setValue(_:for:)`` stores the sanitised value; reads return it.
/// - ``removeValue(for:)`` restores the default; removing twice succeeds.
/// - Keys are independent of each other.
public protocol SettingsStore: Sendable {
    func value<Value>(for key: SettingKey<Value>) -> Value
    func setValue<Value>(_ value: Value, for key: SettingKey<Value>)
    func removeValue<Value>(for key: SettingKey<Value>)
}

/// In-memory ``SettingsStore`` for tests and previews. Nothing is persisted.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`. Values are
    // property-list objects (NSNumber), which are immutable.
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    public init() {}

    /// Stores a raw property-list object, bypassing type checks, to simulate
    /// what another app version (or a user editing defaults) left behind.
    public func setRawObject(_ object: Any?, forName name: String) {
        lock.withLock { storage[name] = object }
    }

    public func value<Value>(for key: SettingKey<Value>) -> Value {
        key.resolve(storedObject: lock.withLock { storage[key.name] })
    }

    public func setValue<Value>(_ value: Value, for key: SettingKey<Value>) {
        let object = key.sanitize(value).propertyListValue
        lock.withLock { storage[key.name] = object }
    }

    public func removeValue<Value>(for key: SettingKey<Value>) {
        _ = lock.withLock { storage.removeValue(forKey: key.name) }
    }
}

/// Observable view of a ``SettingsStore`` for SwiftUI. Reads come from a
/// cache filled from the store; writes are sanitised, cached and written
/// through to the store at once.
@MainActor
@Observable
public final class SettingsModel {
    @ObservationIgnored private let store: any SettingsStore
    private var cache: [String: any SettingValue] = [:]

    public init(store: any SettingsStore) {
        self.store = store
    }

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            if let cached = cache[key.name] as? Value { return cached }
            return store.value(for: key)
        }
        set {
            let value = key.sanitize(newValue)
            store.setValue(value, for: key)
            // Skip same-value writes so observers are not invalidated needlessly.
            guard cache[key.name] as? Value != value else { return }
            cache[key.name] = value
        }
    }

    /// Restores `key`'s default.
    public func reset<Value>(_ key: SettingKey<Value>) {
        store.removeValue(for: key)
        cache[key.name] = nil
    }
}
