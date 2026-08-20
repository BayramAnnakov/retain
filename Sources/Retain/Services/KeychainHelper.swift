import Foundation
import LocalAuthentication
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
    /// Tries Data Protection keychain first, then falls back to standard generic password if entitlement is missing
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing item first
        try? delete(key: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var status = SecItemAdd(query as CFDictionary, nil)

        // If Data Protection keychain lacks entitlement, fallback to standard generic password
        if status == errSecMissingEntitlement && useDataProtection {
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemAdd(query as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            print("⚠️ Keychain save failed with status: \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Get a value from Keychain
    /// Checks Data Protection keychain first, then falls back to standard generic password
    static func get(key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        // Fallback if not found or missing entitlement in Data Protection keychain
        if (status == errSecItemNotFound || status == errSecMissingEntitlement) && useDataProtection {
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Delete a value from Keychain
    static func delete(key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            _ = SecItemDelete(query as CFDictionary)
        }

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

    // MARK: - Login Keychain Cleanup

    /// Key to track if cleanup has been performed (stored in UserDefaults, not keychain)
    private static let cleanupPerformedKey = "Retain.LoginKeychainCleanupPerformed"

    /// One-time cleanup of legacy items from the login keychain.
    /// This removes old keychain items that were stored without Data Protection,
    /// which can trigger authorization prompts when the app's code signature changes.
    ///
    /// This function intentionally does NOT use kSecUseDataProtectionKeychain
    /// so it can find and delete items in the login keychain.
    ///
    /// Call this once on app launch. It tracks whether cleanup was already done
    /// to avoid repeated keychain access.
    static func cleanupLoginKeychain() {
        // Check if cleanup was already done
        if UserDefaults.standard.bool(forKey: cleanupPerformedKey) {
            return
        }

        // Mark as done immediately to prevent repeated attempts even if cleanup fails
        UserDefaults.standard.set(true, forKey: cleanupPerformedKey)

        // Delete all known keys from the LOGIN keychain (without Data Protection flag)
        // This will silently fail if items don't exist, which is fine
        let keysToCleanup = Key.allCases.map { $0.rawValue } + [
            // Legacy keys from development
            "cookies_claude_web",
            "cookies_chatgpt_web",
        ]

        let legacyServices = [service, "com.omni-ai"]

        // Create LAContext that prevents user interaction
        let context = LAContext()
        context.interactionNotAllowed = true

        for legacyService in legacyServices {
            for key in keysToCleanup {
                // Query WITHOUT kSecUseDataProtectionKeychain to target login keychain
                // Use LAContext with interactionNotAllowed to prevent prompts during cleanup
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyService,
                    kSecAttrAccount as String: key,
                    kSecUseAuthenticationContext as String: context
                ]

                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess {
                    print("🧹 Cleaned up legacy keychain item: \(legacyService)/\(key)")
                } else if status == errSecInteractionNotAllowed {
                    // Item exists but we can't delete without user interaction - that's OK
                    print("⚠️ Cannot delete legacy keychain item silently: \(legacyService)/\(key)")
                }
                // Ignore other errors - item might not exist
            }
        }

        print("✅ Login keychain cleanup completed")
    }

    /// Migrate cookies from login keychain to Data Protection keychain (one-time)
    /// DISABLED: No longer needed. Legacy items are cleaned up instead of migrated.
    static func migrateFromLoginKeychain() {
        // DISABLED: Migration reads from login keychain which triggers system
        // Keychain authorization prompts. Users can simply reconnect to web
        // services to get new cookies instead of migrating old ones.
        //
        // cleanupLoginKeychain() is used instead to remove old items.
    }
}
