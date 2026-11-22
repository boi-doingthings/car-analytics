import Foundation
import Security

/// Bluelink login, stored only in the Keychain (never in files, defaults or logs).
enum Credentials {
    struct KeychainError: Error { let status: OSStatus }

    static let defaultService = "com.i20logbook.app.bluelink"
    private static let account = "login"

    private static func baseQuery(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(username: String, password: String, service: String = defaultService) throws {
        let blob = try JSONEncoder().encode([username, password])
        let update: [String: Any] = [kSecValueData as String: blob,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(baseQuery(service) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery(service).merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(service: String = defaultService) -> (String, String)? {
        var q = baseQuery(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let pair = try? JSONDecoder().decode([String].self, from: data), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    static func clear(service: String = defaultService) {
        SecItemDelete(baseQuery(service) as CFDictionary)
    }
}
