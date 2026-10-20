import Foundation
import Security
import UnrealityCore

/// ``SecretStore`` backed by the macOS Keychain (generic-password items).
///
/// Each secret is one item whose `kSecAttrService` is ``service`` and whose
/// `kSecAttrAccount` is the ``SecretKey``'s raw value. The service is the
/// namespace: the app uses ``defaultService`` (the bundle ID); tests pass a
/// unique service so they never read or modify the user's real items.
///
/// Items live in the login (file-based) keychain, which works for unsigned
/// `swift test` binaries and ad-hoc builds; the data-protection keychain
/// would need a keychain-access-groups entitlement and a real signing
/// identity. Items are readable only while the user is logged in and the
/// keychain is unlocked, and are not synchronised to iCloud.
///
/// Nothing here logs. Errors carry only the key name and an `OSStatus`.
public struct KeychainSecretStore: SecretStore {
    /// Service used by the app: the bundle identifier.
    public static let defaultService = AppIdentity.bundleIdentifier

    /// Keychain service (namespace) for every item this store touches.
    public let service: String

    /// Creates a store for `service`. Pass a unique service in tests.
    public init(service: String = KeychainSecretStore.defaultService) {
        precondition(!service.isEmpty, "Keychain service must not be empty")
        self.service = service
    }

    public func secret(for key: SecretKey) throws(SecretStoreError) -> SecretValue? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let plaintext = String(data: data, encoding: .utf8),
                  let value = SecretValue(plaintext) else {
                throw .corruptItem(key)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: status, key: key)
        }
    }

    public func setSecret(_ value: SecretValue, for key: SecretKey) throws(SecretStoreError) {
        let data = Data(value.reveal().utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(for: key)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "\(AppIdentity.displayName) (\(key.rawValue))"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(for: addStatus, key: key) }
        default:
            throw Self.error(for: updateStatus, key: key)
        }
    }

    public func removeSecret(for key: SecretKey) throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status, key: key)
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }

    private static func error(for status: OSStatus, key: SecretKey) -> SecretStoreError {
        switch status {
        case errSecAuthFailed, errSecUserCanceled:
            .accessDenied(key)
        case errSecInteractionNotAllowed:
            .interactionNotAllowed(key)
        default:
            .unexpectedStatus(status, key)
        }
    }
}
