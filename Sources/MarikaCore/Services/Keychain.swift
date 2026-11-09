import Foundation
import Security

/// Stores the API key a user types into Marika's settings. This is only ever a key the user
/// chose to enter here. Marika does not read any other app's credentials.
public enum Keychain {
    private static let service = "app.marika.credentials"

    /// Injectable Security calls let regression tests exercise failures without accessing
    /// the user's Keychain or storing test credentials there.
    struct Operations {
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var add: (CFDictionary) -> OSStatus
        var delete: (CFDictionary) -> OSStatus

        static var system: Operations {
            Operations(update: { SecItemUpdate($0, $1) },
                       add: { SecItemAdd($0, nil) }, delete: { SecItemDelete($0) })
        }
    }

    public static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func write(_ value: String?, account: String) -> Bool {
        write(value, account: account, operations: .system)
    }

    static func write(_ value: String?, account: String, operations: Operations) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let status = operations.delete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let changes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        // Updating in place preserves the saved credential if Keychain rejects a change.
        let status = operations.update(query as CFDictionary, changes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var attributes = query
        attributes.merge(changes) { _, new in new }
        let added = operations.add(attributes as CFDictionary)
        // Another caller may have created it since the initial update.
        if added == errSecDuplicateItem { return operations.update(query as CFDictionary, changes as CFDictionary) == errSecSuccess }
        return added == errSecSuccess
    }

    public static let anthropicAPIKey = "anthropic-api-key"
}
