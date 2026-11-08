import Foundation

#if canImport(Security)
import Security
#endif

/// Where this app keeps the two secrets it owns: the device's Ed25519 private key
/// (proving the device on every token exchange) and the refresh token the host issued
/// at pairing.
///
/// Keychain on device; a dictionary in previews. Nothing else in the app is allowed to
/// write a secret to `UserDefaults` — `HostStore` deliberately takes a `SecretStore`
/// rather than reaching for the Keychain itself, so a preview or a test never touches
/// the real one.
protocol SecretStore {
    func data(for key: String) -> Data?
    func set(_ data: Data, for key: String)
    func remove(_ key: String)
}

#if canImport(Security)
struct KeychainSecretStore: SecretStore {
    var service: String = "dev.hermey.app.mobile"

    func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func set(_ data: Data, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Nothing in this app runs before the first unlock (no background modes), so the
            // stricter class costs nothing and keeps the refresh token unreadable while locked.
            // This-device-only keeps it out of backups and iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#else
/// TODO(platform): Security is always available on iOS; this exists so the file still
/// parses in a Linux typecheck of the package.
struct KeychainSecretStore: SecretStore {
    private static var values: [String: Data] = [:]
    func data(for key: String) -> Data? { Self.values[key] }
    func set(_ data: Data, for key: String) { Self.values[key] = data }
    func remove(_ key: String) { Self.values[key] = nil }
}
#endif

/// The preview/test store: never persists, never prompts.
final class MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}
