import Foundation
import Testing
import UnrealityCore

// The SettingsStore contract, checked against the in-memory fake. The same
// behaviour is checked against UserDefaults by UserDefaultsSettingsStoreTests
// in UnrealityPlatformTests.

private let threshold = AppSettings.idleThresholdMinutes

@Suite("SettingsStore contract (InMemorySettingsStore)")
struct SettingsStoreContractTests {
    let store = InMemorySettingsStore()

    @Test("unset key reads as its default")
    func defaults() {
        #expect(store.value(for: AppSettings.idleThresholdMinutes) == 5)
        #expect(store.value(for: AppSettings.rawCaptureRetentionHours) == 24)
        #expect(store.value(for: AppSettings.contentRetentionDays) == 30)
    }

    @Test("set then get round-trips the value")
    func roundTrip() {
        store.setValue(12, for: threshold)
        #expect(store.value(for: threshold) == 12)
    }

    @Test("set replaces an existing value")
    func overwrite() {
        store.setValue(12, for: threshold)
        store.setValue(7, for: threshold)
        #expect(store.value(for: threshold) == 7)
    }

    @Test("out-of-range writes are clamped")
    func clampsWrites() {
        store.setValue(0, for: threshold)
        #expect(store.value(for: threshold) == 1)
        store.setValue(10_000, for: threshold)
        #expect(store.value(for: threshold) == 60)
        store.setValue(-3, for: AppSettings.rawCaptureRetentionHours)
        #expect(store.value(for: AppSettings.rawCaptureRetentionHours) == 1)
    }

    @Test("remove restores the default and is idempotent")
    func remove() {
        store.setValue(12, for: threshold)
        store.removeValue(for: threshold)
        store.removeValue(for: threshold)
        #expect(store.value(for: threshold) == 5)
    }

    @Test("keys are independent")
    func independentKeys() {
        store.setValue(12, for: threshold)
        store.setValue(3, for: AppSettings.contentRetentionDays)
        store.removeValue(for: threshold)
        #expect(store.value(for: threshold) == 5)
        #expect(store.value(for: AppSettings.contentRetentionDays) == 3)
    }

    @Test("stored values of the wrong type read as the default")
    func wrongType() {
        for junk: Any in ["12", true, 2.5, Data([1]), [12]] {
            store.setRawObject(junk, forName: threshold.name)
            #expect(store.value(for: threshold) == 5, "\(type(of: junk))")
        }
    }

    @Test("stored out-of-range values are clamped on read")
    func clampsReads() {
        store.setRawObject(NSNumber(value: 999), forName: threshold.name)
        #expect(store.value(for: threshold) == 60)
    }
}

@Suite("SettingKey and Settings")
struct SettingKeyTests {
    @Test("defaults lie in range and names are unique")
    func registry() {
        let keys = [
            AppSettings.idleThresholdMinutes, AppSettings.rawCaptureRetentionHours, AppSettings.contentRetentionDays
        ]
        #expect(Set(keys.map(\.name)) == AppSettings.allNames)
        #expect(AppSettings.allNames.count == keys.count)
        for key in keys {
            #expect(key.sanitize(key.defaultValue) == key.defaultValue, "\(key.name)")
        }
    }

    @Test("Int decoding rejects Bool and floating-point numbers")
    func intDecoding() {
        #expect(Int(propertyListValue: NSNumber(value: 4)) == 4)
        #expect(Int(propertyListValue: NSNumber(value: true)) == nil)
        #expect(Int(propertyListValue: NSNumber(value: 4.0)) == nil)
        #expect(Int(propertyListValue: "4") == nil)
    }

    @Test("Bool decoding accepts only Bool numbers")
    func boolDecoding() {
        #expect(Bool(propertyListValue: NSNumber(value: true)) == true)
        #expect(Bool(propertyListValue: NSNumber(value: 1)) == nil)
        #expect(Bool(propertyListValue: "true") == nil)
        let key = SettingKey<Bool>("flag", default: false)
        #expect(key.resolve(storedObject: nil) == false)
        #expect(key.resolve(storedObject: true.propertyListValue) == true)
    }
}

@MainActor
@Suite("SettingsModel")
struct SettingsModelTests {
    let store = InMemorySettingsStore()

    @Test("reads values already in the store")
    func readsStore() {
        store.setValue(9, for: threshold)
        let model = SettingsModel(store: store)
        #expect(model[threshold] == 9)
        #expect(model[AppSettings.contentRetentionDays] == 30)
    }

    @Test("writes go through to the store, sanitised")
    func writesThrough() {
        let model = SettingsModel(store: store)
        model[threshold] = 15
        #expect(store.value(for: threshold) == 15)
        model[threshold] = 0
        #expect(model[threshold] == 1)
        #expect(store.value(for: threshold) == 1)
    }

    @Test("a new model over the same store sees earlier writes")
    func persistsAcrossModels() {
        SettingsModel(store: store)[AppSettings.contentRetentionDays] = 90
        #expect(SettingsModel(store: store)[AppSettings.contentRetentionDays] == 90)
    }

    @Test("reset restores the default")
    func reset() {
        let model = SettingsModel(store: store)
        model[threshold] = 20
        model.reset(threshold)
        #expect(model[threshold] == 5)
        #expect(store.value(for: threshold) == 5)
    }

    @Test("writes notify observers; same-value writes do not")
    func observation() {
        let model = SettingsModel(store: store)
        model[threshold] = 10
        let unchanged = SettingsChangeFlag()
        withObservationTracking { _ = model[threshold] } onChange: { unchanged.set() }
        model[threshold] = 10
        #expect(!unchanged.value)

        let changed = SettingsChangeFlag()
        withObservationTracking { _ = model[threshold] } onChange: { changed.set() }
        model[threshold] = 11
        #expect(changed.value)
    }
}

/// Sendable box for the `@Sendable` onChange closure.
private final class SettingsChangeFlag: @unchecked Sendable {
    // Only touched synchronously on the main actor within one test.
    private(set) var value = false
    func set() { value = true }
}
