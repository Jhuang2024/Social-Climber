import Foundation
import Security

enum KeychainService {
    private static let service = "com.jerryhuang.SocialClimber"
    private static let openRouterAccount = "openrouter-api-key"
    private static let bazaarLinkAccount = "bazaarlink-api-key"
    private static let googleRefreshTokenAccount = "google-calendar-refresh-token"
    private static let lastKnownRecordCountAccount = "last-known-record-count"
    private static let googleDriveRefreshTokenAccount = "google-drive-refresh-token"

    static func openRouterAPIKey() throws -> String {
        guard let key = try read(account: openRouterAccount), !key.isEmpty else {
            throw AIServiceError.missingAPIKey
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

    static func bazaarLinkAPIKey() throws -> String {
        guard let key = try read(account: bazaarLinkAccount), !key.isEmpty else {
            throw AIServiceError.missingAPIKey
        }
        return key
    }

    static func hasBazaarLinkAPIKey() -> Bool {
        (try? bazaarLinkAPIKey()) != nil
    }

    static func saveBazaarLinkAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: bazaarLinkAccount)
        } else {
            try save(trimmed, account: bazaarLinkAccount)
        }
    }

    /// Whether AI features have anything to work with at all: either key
    /// alone is enough (see AIGatewayProvider / BazaarLinkAIService, which
    /// tries OpenRouter first and falls back to BazaarLink).
    static func hasAnyAIKey() -> Bool {
        hasOpenRouterAPIKey() || hasBazaarLinkAPIKey()
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

    // MARK: Data-loss detection

    /// The record count Social Climber last confirmed as real, so
    /// `DataLossGuard` can tell "a fresh install" apart from "data silently
    /// vanished." Deliberately kept in the Keychain rather than
    /// `UserDefaults` or a file: Keychain items are the one thing on iOS
    /// that survives an app delete + reinstall by default, which is exactly
    /// the failure mode this exists to catch.
    static func lastKnownRecordCount() -> Int? {
        let raw = (try? read(account: lastKnownRecordCountAccount)) ?? nil
        return raw.flatMap(Int.init)
    }

    static func setLastKnownRecordCount(_ count: Int) {
        try? save(String(count), account: lastKnownRecordCountAccount)
    }

    static func googleDriveRefreshToken() throws -> String? {
        try read(account: googleDriveRefreshTokenAccount)
    }

    static func hasGoogleDriveRefreshToken() -> Bool {
        (try? googleDriveRefreshToken())?.isEmpty == false
    }

    static func saveGoogleDriveRefreshToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: googleDriveRefreshTokenAccount)
        } else {
            try save(trimmed, account: googleDriveRefreshTokenAccount)
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
