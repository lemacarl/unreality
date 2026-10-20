import Foundation
import Testing
import UnrealityCore
import UnrealityPlatform

@Suite("KeychainSecretStore configuration")
struct KeychainSecretStoreTests {
    @Test("default service is the bundle identifier")
    func defaultService() {
        #expect(KeychainSecretStore.defaultService == AppIdentity.bundleIdentifier)
        #expect(KeychainSecretStore().service == AppIdentity.bundleIdentifier)
    }

    @Test("service namespace is injectable")
    func injectedService() {
        #expect(KeychainSecretStore(service: "example.tests").service == "example.tests")
    }
}

/// Environment variable that enables the real-Keychain integration tests.
/// They are skipped by default (and in CI) because they write to the login
/// keychain of whoever runs them. See CONTRIBUTING.md, "Manual checks".
private let keychainTestsEnabled = ProcessInfo.processInfo.environment["UNREALITY_KEYCHAIN_TESTS"] == "1"

/// Runs the SecretStore contract against the real Keychain, in a unique
/// throwaway service so the user's real items are never read or touched.
/// Every test removes the items it created.
@Suite(
    "KeychainSecretStore integration (manual, UNREALITY_KEYCHAIN_TESTS=1)",
    .enabled(if: keychainTestsEnabled, "Touches the login keychain; set UNREALITY_KEYCHAIN_TESTS=1 to run"),
    .serialized
)
struct KeychainSecretStoreIntegrationTests {
    let store = KeychainSecretStore(service: "com.lemacarl.unreality.tests.\(UUID().uuidString)")

    private func withKeys(
        _ names: [String],
        _ body: ([SecretKey]) throws -> Void
    ) throws {
        let keys = try names.map { try #require(SecretKey($0)) }
        defer {
            for key in keys {
                try? store.removeSecret(for: key)
            }
        }
        try body(keys)
        for key in keys {
            try store.removeSecret(for: key)
            #expect(try store.secret(for: key) == nil, "test item left behind")
        }
    }

    private func value(_ plaintext: String) throws -> SecretValue {
        try #require(SecretValue(plaintext))
    }

    @Test("missing key reads as nil")
    func missingKeyIsNil() throws {
        try withKeys(["absent"]) { keys throws in
            #expect(try store.secret(for: keys[0]) == nil)
        }
    }

    @Test("set, get, overwrite and remove round-trip")
    func roundTrip() throws {
        try withKeys(["api-key"]) { keys throws in
            let key = keys[0]
            try store.setSecret(value("sk-test-ünïcødé-1"), for: key)
            #expect(try store.secret(for: key) == value("sk-test-ünïcødé-1"))

            try store.setSecret(value("sk-test-2"), for: key)
            #expect(try store.secret(for: key) == value("sk-test-2"))

            try store.removeSecret(for: key)
            #expect(try store.secret(for: key) == nil)
            try store.removeSecret(for: key)
        }
    }

    @Test("keys and services are independent")
    func isolation() throws {
        try withKeys(["first", "second"]) { keys throws in
            try store.setSecret(value("one"), for: keys[0])
            try store.setSecret(value("two"), for: keys[1])
            try store.removeSecret(for: keys[0])
            #expect(try store.secret(for: keys[0]) == nil)
            #expect(try store.secret(for: keys[1]) == value("two"))

            let otherService = KeychainSecretStore(service: store.service + ".other")
            #expect(try otherService.secret(for: keys[1]) == nil)
        }
    }
}
