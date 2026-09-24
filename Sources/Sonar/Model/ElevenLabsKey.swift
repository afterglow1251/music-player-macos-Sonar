import Foundation
import Security

/// The user's ElevenLabs API key, kept in the macOS Keychain — never in prefs or a
/// file. The key itself is read only when a request needs it; the UI works off
/// `masked`, a recognisable-but-harmless form ("sk_890f••••3155") so you can tell
/// which key is saved without it ever being shown in full.
@MainActor
final class ElevenLabsKey: ObservableObject {
    static let shared = ElevenLabsKey()

    /// The saved key with its middle hidden, or nil when none is saved.
    @Published private(set) var masked: String?

    nonisolated private static let service = "com.afterglow.sonar.elevenlabs"
    nonisolated private static let account = "api-key"

    /// Only the item's *label* is read here — the masked form, stored beside the
    /// key. Reading the key itself makes macOS ask for Keychain access, so doing
    /// that at every launch just to show the masked key meant a prompt every start.
    private init() {
        masked = Self.savedLabel()
    }

    var isSet: Bool { masked != nil }

    /// Save (or replace) the key. Surrounding whitespace from a paste is dropped.
    func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        SecItemDelete(Self.query as CFDictionary)
        var item = Self.query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = Self.mask(key)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        masked = Self.mask(key)
    }

    func remove() {
        SecItemDelete(Self.query as CFDictionary)
        masked = nil
    }

    /// The key itself, for a request. Nil when none is saved.
    nonisolated static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The saved item's label (the masked key), read without touching the secret.
    nonisolated private static func savedLabel() -> String? {
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        // An item saved before the label existed still counts as a saved key.
        return attributes[kSecAttrLabel as String] as? String ?? String(repeating: "•", count: 8)
    }

    nonisolated private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// "sk_890fa1177…b353155" → "sk_890f••••3155": the prefix and last four,
    /// enough to match against the key list on elevenlabs.io.
    nonisolated static func mask(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: 8) }
        return key.prefix(7) + String(repeating: "•", count: 8) + key.suffix(4)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Couldn't save to the Keychain (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))"
        }
    }
}
