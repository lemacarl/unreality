import Foundation
import Testing
import UnrealityCore

// The SecretStore contract, checked against the in-memory fake. The same
// behaviour is checked against the real Keychain by the opt-in
// KeychainSecretStoreIntegrationTests in UnrealityPlatformTests.

private func key(_ name: String) throws -> SecretKey {
    try #require(SecretKey(name))
}

private func value(_ plaintext: String) throws -> SecretValue {
    try #require(SecretValue(plaintext))
}

@Suite("SecretStore contract (InMemorySecretStore)")
struct SecretStoreContractTests {
    let store: any SecretStore = InMemorySecretStore()

    @Test("missing key reads as nil")
    func missingKeyIsNil() throws {
        #expect(try store.secret(for: key("absent")) == nil)
    }

    @Test("set then get round-trips the value")
    func roundTrip() throws {
        let apiKey = try value("sk-test-round-trip-ünïcødé")
        try store.setSecret(apiKey, for: .claudeAPIKey)
        #expect(try store.secret(for: .claudeAPIKey) == apiKey)
        #expect(try store.secret(for: .claudeAPIKey)?.reveal() == "sk-test-round-trip-ünïcødé")
    }

    @Test("set replaces an existing value")
    func overwrite() throws {
        try store.setSecret(value("first"), for: .claudeAPIKey)
        try store.setSecret(value("second"), for: .claudeAPIKey)
        #expect(try store.secret(for: .claudeAPIKey) == value("second"))
    }

    @Test("remove deletes the value")
    func remove() throws {
        try store.setSecret(value("doomed"), for: .claudeAPIKey)
        try store.removeSecret(for: .claudeAPIKey)
        #expect(try store.secret(for: .claudeAPIKey) == nil)
    }

    @Test("removing a missing key succeeds")
    func removeMissingIsIdempotent() throws {
        try store.removeSecret(for: key("never-set"))
        try store.removeSecret(for: key("never-set"))
    }

    @Test("keys are independent")
    func keysAreIndependent() throws {
        let first = try key("first")
        let second = try key("second")
        try store.setSecret(value("one"), for: first)
        try store.setSecret(value("two"), for: second)
        try store.removeSecret(for: first)
        #expect(try store.secret(for: first) == nil)
        #expect(try store.secret(for: second) == value("two"))
    }

    @Test("initial contents are readable")
    func prepopulated() throws {
        let seeded = InMemorySecretStore([.claudeAPIKey: try value("seeded")])
        #expect(try seeded.secret(for: .claudeAPIKey) == value("seeded"))
    }

    @Test("concurrent writes and reads are safe")
    func concurrentAccess() async throws {
        let store = InMemorySecretStore()
        let pairs = try (0..<50).map { (try key("k\($0)"), try value("v\($0)")) }
        await withTaskGroup(of: Void.self) { group in
            for (key, value) in pairs {
                group.addTask {
                    try? store.setSecret(value, for: key)
                    _ = try? store.secret(for: key)
                }
            }
        }
        for (key, value) in pairs {
            #expect(try store.secret(for: key) == value)
        }
    }
}

@Suite("SecretKey and SecretValue")
struct SecretTypesTests {
    @Test("empty or blank key names are rejected", arguments: ["", " ", "\n\t"])
    func blankKeyRejected(name: String) {
        #expect(SecretKey(name) == nil)
    }

    @Test("empty secret values are rejected")
    func emptyValueRejected() {
        #expect(SecretValue("") == nil)
    }

    @Test("Claude API key has a stable account name")
    func claudeAPIKeyName() {
        #expect(SecretKey.claudeAPIKey.rawValue == "claude-api-key")
    }

    @Test("secret values are redacted in every textual representation")
    func valueIsRedacted() throws {
        let plaintext = "sk-ant-do-not-log-me"
        let secret = try value(plaintext)
        var dumped = ""
        dump(secret, to: &dumped)
        let renderings = [
            String(describing: secret),
            String(reflecting: secret),
            "\(secret)",
            dumped,
            String(describing: Optional(secret)),
            String(describing: [SecretKey.claudeAPIKey: secret])
        ]
        for rendering in renderings {
            #expect(!rendering.contains(plaintext))
            #expect(rendering.contains("redacted"))
        }
    }

    // Errors carry only a SecretKey and a status code, so they cannot hold a
    // secret; check that the description still names the key for debugging.
    @Test("error descriptions name the key")
    func errorDescriptionsNameKey() {
        let errors: [SecretStoreError] = [
            .corruptItem(.claudeAPIKey),
            .accessDenied(.claudeAPIKey),
            .interactionNotAllowed(.claudeAPIKey),
            .unexpectedStatus(-25_300, .claudeAPIKey)
        ]
        for error in errors {
            #expect(String(describing: error).contains("claude-api-key"))
        }
    }
}
