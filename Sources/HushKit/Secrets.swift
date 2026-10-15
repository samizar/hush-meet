import Foundation
import Security
import CryptoKit

/// This is the only application type that reads or writes Keychain items.
public enum Secrets {
    private static let service = "app.hush.mac"
    public static func set(_ value: String, for account: String) throws {
        try setData(Data(value.utf8), for: account)
    }
    public static func get(_ account: String) throws -> String? {
        try data(account).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    public static func storeKey() throws -> SymmetricKey {
        if let data = try data("store-encryption") { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try setData(key.withUnsafeBytes { Data($0) }, for: "store-encryption")
        return key
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private static func data(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        return result as? Data
    }
    private static func setData(_ data: Data, for account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account); q.merge(attributes) { _, new in new }
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw error(added) }
        } else if status != errSecSuccess { throw error(status) }
    }
    private static func error(_ status: OSStatus) -> HushError {
        .message("Couldn't access the Keychain (\(status)). Unlock your login keychain and try again.")
    }
}
