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
    /// Uses Data Protection keychain in release builds (no prompts).
    /// Falls back to login keychain in debug builds (needed when entitlement is missing).
    static func get(key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        // Try Data Protection keychain first (no prompts in release builds)
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8) {
                return value
            }
            // In release builds, if Data Protection fails, don't fall back
            // to avoid unexpected keychain prompts
            #if !DEBUG
            return nil
            #endif
        }

        // Fall back to login keychain only in DEBUG builds
        // (Debug builds lack entitlement, so Data Protection fails)
        #if DEBUG
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
        #else
        return nil
        #endif
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

    // MARK: - Login Keychain Migration

    /// Migrate cookies from login keychain to Data Protection keychain (one-time)
    /// Handles both old per-provider format (cookies_claude_web, cookies_chatgpt_web)
    /// and new combined format (web-session-cookies)
    /// Also checks legacy service name "com.omni-ai" from development builds
    static func migrateFromLoginKeychain() {
        // Only migrate if Data Protection keychain is empty
        guard webSessionCookies == nil else { return }

        // Services to check (current + legacy service names from dev builds)
        let servicesToCheck = [service, "com.omni-ai"]

        // Helper to read from login keychain (without Data Protection flag)
        func readFromLoginKeychain(key: String, svc: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        }

        func deleteFromLoginKeychain(key: String, svc: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(query as CFDictionary)
        }

        // Try old per-provider format first (cookies_claude_web, cookies_chatgpt_web)
        let oldKeys = ["cookies_claude_web": "claude_web", "cookies_chatgpt_web": "chatgpt_web"]
        var combinedCookies: [String: [[String: Any]]] = [:]

        for svc in servicesToCheck {
            for (oldKey, providerKey) in oldKeys {
                if combinedCookies[providerKey] != nil { continue } // Already found
                if let jsonString = readFromLoginKeychain(key: oldKey, svc: svc),
                   let data = jsonString.data(using: .utf8),
                   let cookies = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    #if DEBUG
                    print("🔵 KeychainHelper: Found old format cookies for \(oldKey) in \(svc)")
                    #endif
                    combinedCookies[providerKey] = cookies
                    deleteFromLoginKeychain(key: oldKey, svc: svc)
                }
            }
        }

        if !combinedCookies.isEmpty {
            if let encoded = try? JSONSerialization.data(withJSONObject: combinedCookies),
               let jsonString = String(data: encoded, encoding: .utf8) {
                webSessionCookies = jsonString
                #if DEBUG
                print("🔵 KeychainHelper: Migrated old per-provider cookies to combined format")
                #endif
                return
            }
        }

        // Try new combined format (web-session-cookies in login keychain)
        for svc in servicesToCheck {
            if let value = readFromLoginKeychain(key: Key.webSessionCookies.rawValue, svc: svc), !value.isEmpty {
                webSessionCookies = value
                deleteFromLoginKeychain(key: Key.webSessionCookies.rawValue, svc: svc)
                #if DEBUG
                print("🔵 KeychainHelper: Migrated cookies from login keychain (\(svc))")
                #endif
                return
            }
        }
    }
}
