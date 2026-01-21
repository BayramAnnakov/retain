import Foundation
import Security

/// Simple Keychain wrapper for storing API keys securely.
///
/// Uses iOS-style Data Protection keychain (`kSecUseDataProtectionKeychain`) on macOS 10.15+
/// to avoid system keychain authorization prompts. Items are stored in the app's sandboxed
/// keychain and don't trigger "wants to access your keychain" dialogs.
enum KeychainHelper {
    private static let service = "com.empatika.Retain"

    /// Use iOS-style Data Protection keychain to avoid authorization prompts.
    /// This stores items in a separate keychain that doesn't require user approval.
    private static let useDataProtection: Bool = true

    enum KeychainError: LocalizedError {
        case duplicateItem
        case unexpectedStatus(OSStatus)
        case itemNotFound

        var errorDescription: String? {
            switch self {
            case .duplicateItem:
                return "Item already exists in Keychain"
            case .unexpectedStatus(let status):
                return "Keychain error: \(status)"
            case .itemNotFound:
                return "Item not found in Keychain"
            }
        }
    }

    /// Save a value to Keychain
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing item first (from both keychains)
        try? delete(key: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Try iOS-style Data Protection keychain first (preferred - no prompts)
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var status = SecItemAdd(query as CFDictionary, nil)

        // Fallback to regular keychain if Data Protection fails (-34018 = missing entitlement)
        if status == errSecMissingEntitlement && useDataProtection {
            print("⚠️ Data Protection keychain unavailable, falling back to login keychain")
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemAdd(query as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            print("⚠️ Keychain save failed with status: \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Get a value from Keychain
    /// NOTE: Only reads from Data Protection keychain to avoid authorization prompts.
    /// Items in the legacy login keychain are not accessible without user approval.
    static func get(key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        // Use iOS-style Data Protection keychain (no prompts)
        // DO NOT fall back to login keychain - that triggers authorization prompts
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    /// Delete a value from Keychain (from both Data Protection and login keychains)
    static func delete(key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Delete from Data Protection keychain
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            let dpStatus = SecItemDelete(query as CFDictionary)
            if dpStatus != errSecSuccess && dpStatus != errSecItemNotFound && dpStatus != errSecMissingEntitlement {
                throw KeychainError.unexpectedStatus(dpStatus)
            }
        }

        // Also delete from login keychain (fallback storage)
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Convenience Keys

    enum Key: String, CaseIterable {
        case geminiApiKey = "gemini-api-key"
        case webSessionCookies = "web-session-cookies"
        case chatgptAccessToken = "chatgpt-access-token"
    }

    /// Get Gemini API key from Keychain
    static var geminiApiKey: String? {
        get { get(key: Key.geminiApiKey.rawValue) }
        set {
            if let value = newValue, !value.isEmpty {
                do {
                    try save(key: Key.geminiApiKey.rawValue, value: value)
                    print("✅ Gemini API key saved to Keychain")
                } catch {
                    print("❌ Failed to save Gemini API key: \(error)")
                }
            } else {
                try? delete(key: Key.geminiApiKey.rawValue)
            }
        }
    }

    /// Migrate from UserDefaults to Data Protection keychain.
    /// Call once on app launch.
    static func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        let legacyKey = "geminiApiKey"

        // Check if there's a value in UserDefaults
        if let legacyValue = defaults.string(forKey: legacyKey), !legacyValue.isEmpty {
            // Only migrate if Keychain doesn't already have a value
            if geminiApiKey == nil || geminiApiKey?.isEmpty == true {
                geminiApiKey = legacyValue
            }
            // Clear the UserDefaults value for security
            defaults.removeObject(forKey: legacyKey)
        }

        // Note: We no longer migrate from legacy keychain automatically because
        // reading from the login keychain triggers authorization prompts.
        // Users with existing credentials will need to re-enter them once.
    }

    // MARK: - Web Session Storage

    /// Get/set web session cookies (JSON string)
    static var webSessionCookies: String? {
        get { get(key: Key.webSessionCookies.rawValue) }
        set {
            if let value = newValue, !value.isEmpty {
                try? save(key: Key.webSessionCookies.rawValue, value: value)
            } else {
                try? delete(key: Key.webSessionCookies.rawValue)
            }
        }
    }

    /// Get/set ChatGPT access token
    static var chatgptAccessToken: String? {
        get { get(key: Key.chatgptAccessToken.rawValue) }
        set {
            if let value = newValue, !value.isEmpty {
                try? save(key: Key.chatgptAccessToken.rawValue, value: value)
            } else {
                try? delete(key: Key.chatgptAccessToken.rawValue)
            }
        }
    }
}
