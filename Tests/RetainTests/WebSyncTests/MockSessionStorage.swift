import Foundation
@testable import Retain

/// Mock session storage for testing without Keychain access
final class MockSessionStorage {
    private var cookieCache: [Provider: [HTTPCookie]] = [:]
    private var savedKeys: [String: Data] = [:]

    /// Store session cookies for a provider
    func storeCookies(_ cookies: [HTTPCookie], for provider: Provider) {
        cookieCache[provider] = cookies

        // Simulate Keychain storage
        let cookieData = cookies.compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            var stringDict: [String: Any] = [:]
            for (key, value) in properties {
                stringDict[key.rawValue] = value
            }
            return stringDict
        }

        if let data = try? JSONSerialization.data(withJSONObject: cookieData) {
            savedKeys["cookies_\(provider.rawValue)"] = data
        }
    }

    /// Get stored cookies for a provider
    func getCookies(for provider: Provider) -> [HTTPCookie] {
        if let cached = cookieCache[provider] {
            return cached
        }

        guard let data = savedKeys["cookies_\(provider.rawValue)"],
              let cookieData = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let cookies = cookieData.compactMap { dict -> HTTPCookie? in
            var propertyKeyDict: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in dict {
                propertyKeyDict[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: propertyKeyDict)
        }
        cookieCache[provider] = cookies
        return cookies
    }

    /// Check if valid session exists
    func hasValidSession(for provider: Provider) -> Bool {
        let cookies = getCookies(for: provider)
        return !cookies.isEmpty
    }

    /// Clear session for a provider
    func clearSession(for provider: Provider) {
        cookieCache.removeValue(forKey: provider)
        savedKeys.removeValue(forKey: "cookies_\(provider.rawValue)")
    }

    /// Clear all sessions
    func clearAll() {
        cookieCache.removeAll()
        savedKeys.removeAll()
    }
}

// MARK: - Test Cookie Factory

extension MockSessionStorage {
    /// Create test cookies for a provider
    static func createTestCookies(for provider: Provider) -> [HTTPCookie] {
        let domain: String
        switch provider {
        case .claudeWeb:
            domain = "claude.ai"
        case .chatgptWeb:
            domain = "chatgpt.com"
        default:
            domain = "example.com"
        }

        // Note: Omit .expires to avoid Date serialization issues in JSON
        // These are session cookies which work for testing purposes
        return [
            HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "session",
                .value: "test-session-\(UUID().uuidString)",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "auth",
                .value: "test-auth-\(UUID().uuidString)",
                .secure: "TRUE"
            ])!
        ]
    }
}
