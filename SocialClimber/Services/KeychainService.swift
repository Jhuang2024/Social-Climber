import Foundation
import Security

enum KeychainService {
    private static let service = "com.jerryhuang.SocialClimber"
    private static let openRouterAccount = "openrouter-api-key"
    private static let googleRefreshTokenAccount = "google-calendar-refresh-token"

    static func openRouterAPIKey() throws -> String {
        guard let key = try read(account: openRouterAccount), !key.isEmpty else {
            throw AIServiceError.missingOpenRouterAPIKey
        }
        return key
    }

    static func hasOpenRouterAPIKey() -> Bool {
        (try? openRouterAPIKey()) != nil
    }

    static func saveOpenRouterAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: openRouterAccount)
        } else {
            try save(trimmed, account: openRouterAccount)
        }
    }

    static func googleRefreshToken() throws -> String? {
        try read(account: googleRefreshTokenAccount)
    }

    static func hasGoogleRefreshToken() -> Bool {
        (try? googleRefreshToken())?.isEmpty == false
    }

    static func saveGoogleRefreshToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: googleRefreshTokenAccount)
        } else {
            try save(trimmed, account: googleRefreshTokenAccount)
        }
    }

    private static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "Keychain error \(status)."
        }
    }
}
