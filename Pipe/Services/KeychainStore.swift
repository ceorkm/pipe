import Foundation
import Security
import PipeCore

/// Proxy passwords live in the login Keychain, one generic-password item per proxy id.
enum KeychainStore {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: PipeIdentifiers.keychainService,
         kSecAttrAccount as String: id.uuidString]
    }

    static func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        guard let password, !password.isEmpty else { delete(id); return }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Pipe proxy password"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { Log.app.error("keychain add failed: \(addStatus)") }
        } else if status != errSecSuccess {
            Log.app.error("keychain update failed: \(status)")
        }
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
