import Foundation
import Security
import LocalAuthentication

/// Keychain items for Enkeon's tokens (from Cookie's CookieKeychain, cookie-harness 8ffefde).
enum EnkeonKeychain {
    private static func baseQuery(service: String, account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func read(service: String, account: String, interactive: Bool = true) throws -> Data? {
        for dataProtection in [true, false] {
            var query = baseQuery(service: service, account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if !interactive {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data { return data }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        return nil
    }

    static func add(_ data: Data, service: String, account: String) throws {
        var attributes = baseQuery(service: service, account: account, dataProtection: true)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            attributes = baseQuery(service: service, account: account, dataProtection: false)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Update in place: a failed write must not destroy the last usable tokens.
    static func set(_ data: Data, service: String, account: String) throws {
        for dataProtection in [true, false] {
            let query = baseQuery(service: service, account: account, dataProtection: dataProtection)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        try add(data, service: service, account: account)
    }

    static func delete(service: String, account: String) {
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(service: service, account: account, dataProtection: dataProtection) as CFDictionary)
        }
    }
}
