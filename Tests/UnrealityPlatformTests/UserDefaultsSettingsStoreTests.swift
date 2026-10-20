import Foundation
import Testing
import UnrealityCore
import UnrealityPlatform

/// Each test gets a throwaway defaults suite, removed afterwards, so it never
/// reads or changes the app's real settings.
final class DefaultsSuite {
    let name = "com.lemacarl.unreality.tests.\(UUID().uuidString)"

    func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: name))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: name)
    }
}

@Suite("UserDefaultsSettingsStore")
struct UserDefaultsSettingsStoreTests {
    let suite = DefaultsSuite()
    private let threshold = Settings.idleThresholdMinutes

    @Test("unset key reads as its default")
    func defaults() throws {
        let store = try UserDefaultsSettingsStore(defaults: suite.makeDefaults())
        #expect(store.value(for: threshold) == threshold.defaultValue)
        #expect(store.value(for: Settings.contentRetentionDays) == 30)
    }

    @Test("values persist across store instances (launches)")
    func persists() throws {
        let first = try suite.makeDefaults()
        UserDefaultsSettingsStore(defaults: first).setValue(17, for: threshold)
        first.synchronize()
        // A new UserDefaults object over the same suite, as after a relaunch.
        let store = try UserDefaultsSettingsStore(defaults: suite.makeDefaults())
        #expect(store.value(for: threshold) == 17)
    }

    @Test("writes are clamped; remove restores the default and is idempotent")
    func clampAndRemove() throws {
        let store = try UserDefaultsSettingsStore(defaults: suite.makeDefaults())
        store.setValue(500, for: Settings.rawCaptureRetentionHours)
        #expect(store.value(for: Settings.rawCaptureRetentionHours) == 24)
        store.setValue(3, for: threshold)
        store.removeValue(for: threshold)
        store.removeValue(for: threshold)
        #expect(store.value(for: threshold) == 5)
        #expect(store.value(for: Settings.rawCaptureRetentionHours) == 24)
    }

    @Test("stored values of the wrong type read as the default")
    func wrongType() throws {
        let defaults = try suite.makeDefaults()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        for junk: Any in ["12", true, 2.5, Data([1])] {
            defaults.set(junk, forKey: threshold.name)
            #expect(store.value(for: threshold) == 5, "\(type(of: junk))")
        }
    }

    @Test("writes only the setting's own key, as a plain number")
    func writesOnlyKnownKeys() throws {
        let defaults = try suite.makeDefaults()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.setValue(8, for: threshold)
        store.setValue(12, for: Settings.rawCaptureRetentionHours)
        store.setValue(60, for: Settings.contentRetentionDays)
        let domain = try #require(defaults.persistentDomain(forName: suite.name))
        #expect(Set(domain.keys) == Settings.allNames)
        #expect(domain.values.allSatisfy { $0 is NSNumber })
    }
}
