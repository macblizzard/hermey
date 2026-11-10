import Foundation
import HermesKit
import Security

/// Keeps this Mac's pairing so a relaunch resumes the host instead of asking for a code again.
///
/// Both halves are one item: the URL is not a secret, but the refresh token is — it mints socket
/// tickets — so the two travel together rather than one half landing in a plist next to a token.
///
/// ## Why there is more than one place
///
/// The app ships **unsigned** (FlareStore sideloading). A data-protection keychain item
/// (`kSecUseDataProtectionKeychain`) needs an application identifier, which only a signed build has:
/// unsigned, `SecItemAdd` answers `errSecMissingEntitlement` (-34018), and the old code treated that
/// as "not persisted" — so the pairing lived in memory only and every relaunch asked for a new code.
/// The login keychain needs no entitlement, but it binds the item to the app's signature, and every
/// downloaded build has a new one, so a read can prompt and a denied prompt is a read that fails.
///
/// So the item is written to *both* Keychain variants and to a file, and read from whichever answers
/// first:
///
/// 1. `dataProtectionKeychain` — signed builds; this-device-only, never leaves the Mac.
/// 2. `loginKeychain` — unsigned builds the system still lets through.
/// 3. `file` — `~/Library/Application Support/Hermey/pairing.json`, mode `0600`, excluded from
///    backups. This is what actually keeps an unsigned install paired, and Settings says so instead
///    of pretending the Keychain holds it.
///
/// `clear()` removes all three, so an unpair leaves nothing behind.
final class PairingStore {

    enum Storage: String, Equatable {
        case dataProtectionKeychain
        case loginKeychain
        case file

        /// What to tell the person, in one clause.
        var description: String {
            switch self {
            case .dataProtectionKeychain:
                return "the Keychain (this Mac only)"
            case .loginKeychain:
                return "the login Keychain"
            case .file:
                return "a user-only file (mode 0600, not backed up) — this unsigned build cannot use the Keychain"
            }
        }
    }

    private static let service = "dev.hermey.app.mac.pairing"
    private static let account = "host"
    private static let fileName = "pairing.json"

    /// `false` when nothing could be written, so pairing is session-only.
    private(set) var persisted = false
    /// Where the item was last written, or found on load.
    private(set) var storage: Storage?
    /// The last `OSStatus` the Keychain gave, kept for the log and the diagnostics sheet.
    private(set) var lastKeychainStatus: OSStatus?

    // MARK: Read / write

    func savedAddress() -> PairingAddress? {
        guard let data = read() else {
            storage = nil
            persisted = false
            return nil
        }
        return try? JSONDecoder().decode(PairingAddress.self, from: data)
    }

    @discardableResult
    func save(_ address: PairingAddress) -> Storage? {
        guard let data = try? JSONEncoder().encode(address) else {
            persisted = false
            storage = nil
            ClientLog.note("pairing could not be encoded", level: .error, category: "pairing")
            return nil
        }

        // Replace, not add: SecItemAdd fails with errSecDuplicateItem on a second pair.
        deleteKeychain()

        var written: [Storage] = []
        for variant in [Storage.dataProtectionKeychain, .loginKeychain] {
            let status = addKeychain(data, to: variant)
            lastKeychainStatus = status
            if status == errSecSuccess { written.append(variant) }
        }

        // The durable copy for an unsigned build, and the one a denied Keychain prompt cannot take
        // away. `0600`, this user only, no backup.
        if writeFile(data) { written.append(.file) }

        persisted = !written.isEmpty
        storage = written.first

        if !persisted {
            ClientLog.note(
                "pairing is session-only — Keychain refused (OSStatus \(lastKeychainStatus ?? 0)) and the file could not be written",
                level: .error,
                category: "pairing")
        } else if !written.contains(.dataProtectionKeychain) {
            ClientLog.note(
                "pairing stored in \(written.map(\.rawValue).joined(separator: " + ")) — no data-protection item (OSStatus \(lastKeychainStatus ?? 0)); expected on an unsigned build",
                level: .warning,
                category: "pairing")
        } else {
            ClientLog.note("pairing stored in \(written.map(\.rawValue).joined(separator: " + "))",
                           category: "pairing")
        }
        return storage
    }

    func clear() {
        deleteKeychain()
        removeFile()
        persisted = false
        storage = nil
    }

    // MARK: Keychain

    /// Read the Keychain first — it is the copy that a stolen disk alone cannot open — then the file,
    /// which is what an unsigned build actually has.
    private func read() -> Data? {
        for variant in [Storage.dataProtectionKeychain, .loginKeychain] {
            if let data = readKeychain(from: variant) {
                storage = variant
                persisted = true
                return data
            }
        }
        if let data = readFile() {
            storage = .file
            persisted = true
            return data
        }
        return nil
    }

    private func query(for storage: Storage) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PairingStore.service,
            kSecAttrAccount as String: PairingStore.account,
        ]
        if storage == .dataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func addKeychain(_ data: Data, to storage: Storage) -> OSStatus {
        var query = query(for: storage)
        query[kSecValueData as String] = data
        // Inert on the file-based login keychain, meaningful in the data-protection one.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func readKeychain(from storage: Storage) -> Data? {
        var query = query(for: storage)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            // errSecItemNotFound is ordinary on a fresh install; anything else is worth a line.
            if status != errSecItemNotFound { lastKeychainStatus = status }
            return nil
        }
        return item as? Data
    }

    private func deleteKeychain() {
        for variant in [Storage.dataProtectionKeychain, .loginKeychain] {
            _ = SecItemDelete(query(for: variant) as CFDictionary)
        }
    }

    // MARK: File

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Hermey", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent(PairingStore.fileName, isDirectory: false)
    }

    private func writeFile(_ data: Data) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try? url.setResourceValues(values)
            return true
        } catch {
            ClientLog.note("pairing file could not be written: \(error.localizedDescription)",
                           level: .error,
                           category: "pairing")
            return false
        }
    }

    private func readFile() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    private func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
