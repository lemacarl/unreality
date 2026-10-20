import Foundation
import UnrealityCore

/// `SettingsStore` backed by `UserDefaults`, so settings persist across
/// launches. The app uses `.standard` (the `com.lemacarl.unreality` domain,
/// `~/Library/Preferences/com.lemacarl.unreality.plist`); tests inject a
/// throwaway suite.
///
/// Holds non-secret configuration only: `SettingValue` admits property-list
/// primitives, and secrets go to `KeychainSecretStore`.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    // @unchecked: `UserDefaults` is documented as thread-safe but not
    // annotated `Sendable` in the SDK. This type holds no other state.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value<Value>(for key: SettingKey<Value>) -> Value {
        key.resolve(storedObject: defaults.object(forKey: key.name))
    }

    public func setValue<Value>(_ value: Value, for key: SettingKey<Value>) {
        defaults.set(key.sanitize(value).propertyListValue, forKey: key.name)
    }

    public func removeValue<Value>(for key: SettingKey<Value>) {
        defaults.removeObject(forKey: key.name)
    }
}
