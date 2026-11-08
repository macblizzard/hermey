import Foundation
import Security

/// Keeps this Mac's pairing in the login keychain.
///
/// Both halves are one item: the URL is not a secret, but the refresh token is — it mints
/// socket tickets — so the two travel together rather than one half landing in a plist
/// next to a token. Stored as JSON under a single generic-password item.
///
/// If the keychain refuses (an unsigned build on a locked-down machine), pairing still works
/// for this run and the sheet says so instead of quietly writing the token somewhere worse.
final class PairingStore {

    private static let service = "dev.hermey.app.mac.pairing"
    private static let account = "host"

    /// `false` when the last write did not reach the keychain, so pairing is session-only.
    /// The pair sheet reads this back rather than promising persistence.
    private(set) var persisted = false

    func savedAddress() -> PairingAddress? {
        guard let data = read() else { return nil }
        return try? JSONDecoder().decode(PairingAddress.self, from: data)
    }

    func save(_ address: PairingAddress) {
        guard let data = try? JSONEncoder().encode(address) else {
            persisted = false
            return
        }
        // Replace, not add: SecItemAdd fails with errSecDuplicateItem on a second pair.
        _ = SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        // Without the data-protection keychain this lands in the file-based login keychain, where the
        // accessibility attribute is inert and Time Machine copies it to any restored Mac.
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        persisted = status == errSecSuccess
    }

    func clear() {
        _ = SecItemDelete(baseQuery as CFDictionary)
        persisted = false
    }

    private func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PairingStore.service,
            kSecAttrAccount as String: PairingStore.account,
        ]
    }
}
