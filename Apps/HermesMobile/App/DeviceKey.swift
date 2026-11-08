import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The device identity this phone proves itself with.
///
/// The bridge stores a SHA-256 of the refresh token and the *public* half of an Ed25519
/// key; the private half never leaves the Keychain. Regenerating the key would orphan the
/// paired device, so it is created once and reused.
enum DeviceKey {
    private static let account = "hermes.deviceKey"

    /// 32 raw bytes, standard base64 — what `bridge/pairing.py` normalises and stores.
    static func publicKeyBase64(secrets: SecretStore = KeychainSecretStore()) throws -> String {
        #if canImport(CryptoKit)
        if let raw = secrets.data(for: account),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key.publicKey.rawRepresentation.base64EncodedString()
        }
        let key = Curve25519.Signing.PrivateKey()
        secrets.set(key.rawRepresentation, for: account)
        return key.publicKey.rawRepresentation.base64EncodedString()
        #else
        throw BridgeError.keyUnavailable
        #endif
    }

    static func forget(secrets: SecretStore = KeychainSecretStore()) {
        secrets.remove(account)
    }
}
