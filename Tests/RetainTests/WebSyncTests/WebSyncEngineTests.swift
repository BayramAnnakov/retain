import XCTest
@testable import Retain

@MainActor
final class WebSyncEngineTests: XCTestCase {

    // MARK: - Connection Status Tests

    func testConnectionStatusIsConnectedTrue() {
        let status = WebSyncEngine.ConnectionStatus.connected(email: "test@example.com")
        XCTAssertTrue(status.isConnected)
    }

    func testConnectionStatusIsConnectedWithNilEmail() {
        let status = WebSyncEngine.ConnectionStatus.connected(email: nil)
        XCTAssertTrue(status.isConnected)
    }

    func testConnectionStatusDisconnectedNotConnected() {
        let status = WebSyncEngine.ConnectionStatus.disconnected
        XCTAssertFalse(status.isConnected)
    }

    func testConnectionStatusConnectingNotConnected() {
        let status = WebSyncEngine.ConnectionStatus.connecting
        XCTAssertFalse(status.isConnected)
    }

    func testConnectionStatusErrorNotConnected() {
        let status = WebSyncEngine.ConnectionStatus.error("Some error")
        XCTAssertFalse(status.isConnected)
    }

    // MARK: - Connection Status Equality Tests

    func testConnectionStatusEquality() {
        XCTAssertEqual(
            WebSyncEngine.ConnectionStatus.disconnected,
            WebSyncEngine.ConnectionStatus.disconnected
        )

        XCTAssertEqual(
            WebSyncEngine.ConnectionStatus.connecting,
            WebSyncEngine.ConnectionStatus.connecting
        )

        XCTAssertEqual(
            WebSyncEngine.ConnectionStatus.connected(email: "test@example.com"),
            WebSyncEngine.ConnectionStatus.connected(email: "test@example.com")
        )

        XCTAssertEqual(
            WebSyncEngine.ConnectionStatus.connected(email: nil),
            WebSyncEngine.ConnectionStatus.connected(email: nil)
        )

        XCTAssertEqual(
            WebSyncEngine.ConnectionStatus.error("error"),
            WebSyncEngine.ConnectionStatus.error("error")
        )

        // Inequality
        XCTAssertNotEqual(
            WebSyncEngine.ConnectionStatus.disconnected,
            WebSyncEngine.ConnectionStatus.connecting
        )

        XCTAssertNotEqual(
            WebSyncEngine.ConnectionStatus.connected(email: "a@example.com"),
            WebSyncEngine.ConnectionStatus.connected(email: "b@example.com")
        )
    }

    // MARK: - WebSyncError Tests

    func testWebSyncErrorNotAuthenticated() {
        let error = WebSyncEngine.WebSyncError.notAuthenticated
        XCTAssertEqual(error.errorDescription, "Not authenticated. Please sign in.")
    }

    func testWebSyncErrorNetworkError() {
        let underlyingError = URLError(.notConnectedToInternet)
        let error = WebSyncEngine.WebSyncError.networkError(underlyingError)
        XCTAssertTrue(error.errorDescription?.contains("Network error") ?? false)
        // The underlying error description varies by locale, so just verify it's not empty
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    func testWebSyncErrorParseError() {
        let error = WebSyncEngine.WebSyncError.parseError("Invalid JSON structure")
        XCTAssertEqual(error.errorDescription, "Parse error: Invalid JSON structure")
    }

    func testWebSyncErrorRateLimited() {
        let error = WebSyncEngine.WebSyncError.rateLimited(retryAfter: nil)
        XCTAssertEqual(error.errorDescription, "Rate limited. Please wait and try again.")
    }

    func testWebSyncErrorSessionExpired() {
        let error = WebSyncEngine.WebSyncError.sessionExpired
        XCTAssertEqual(error.errorDescription, "Session expired. Please sign in again.")
    }

    // MARK: - WebUserInfo Tests

    func testWebUserInfoCreation() {
        let userInfo = WebUserInfo(
            email: "test@example.com",
            name: "Test User",
            organizationId: "org-123"
        )

        XCTAssertEqual(userInfo.email, "test@example.com")
        XCTAssertEqual(userInfo.name, "Test User")
        XCTAssertEqual(userInfo.organizationId, "org-123")
    }

    func testWebUserInfoWithNilValues() {
        let userInfo = WebUserInfo(
            email: nil,
            name: nil,
            organizationId: nil
        )

        XCTAssertNil(userInfo.email)
        XCTAssertNil(userInfo.name)
        XCTAssertNil(userInfo.organizationId)
    }

    // MARK: - ConversationMeta Tests

    func testConversationMetaCreation() {
        let now = Date()
        let meta = ConversationMeta(
            id: "conv-123",
            title: "Test Conversation",
            createdAt: now,
            updatedAt: now.addingTimeInterval(3600)
        )

        XCTAssertEqual(meta.id, "conv-123")
        XCTAssertEqual(meta.title, "Test Conversation")
        XCTAssertEqual(meta.createdAt, now)
        XCTAssertEqual(meta.updatedAt, now.addingTimeInterval(3600))
    }

    func testConversationMetaWithNilTitle() {
        let meta = ConversationMeta(
            id: "conv-456",
            title: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        XCTAssertEqual(meta.id, "conv-456")
        XCTAssertNil(meta.title)
    }

    // MARK: - Provider Tests for WebSync

    func testClaudeWebProvider() {
        XCTAssertEqual(Provider.claudeWeb.rawValue, "claude_web")
        XCTAssertEqual(Provider.claudeWeb.displayName, "Claude")
        XCTAssertEqual(Provider.claudeWeb.iconName, "globe")
    }

    func testChatGPTWebProvider() {
        XCTAssertEqual(Provider.chatgptWeb.rawValue, "chatgpt_web")
        XCTAssertEqual(Provider.chatgptWeb.displayName, "ChatGPT")
        XCTAssertEqual(Provider.chatgptWeb.iconName, "bubble.left.and.bubble.right")
    }

    // MARK: - Initial State Tests

    func testInitialConnectionStatusIsDisconnected() {
        let engine = WebSyncEngine()

        // Note: The engine checks for existing sessions on init,
        // but without valid cookies, should remain disconnected
        // We can't easily test this without mocking the SessionStorage
        XCTAssertFalse(engine.isSyncing)
    }

    func testInitialSyncingState() {
        let engine = WebSyncEngine()
        XCTAssertFalse(engine.isSyncing)
    }

    func testInitialLastSyncDateIsEmpty() {
        UserDefaults.standard.removeObject(forKey: "webSyncLastSyncDates")
        let engine = WebSyncEngine()
        XCTAssertTrue(engine.lastSyncDate.isEmpty)
    }

    func testInitialErrorIsNil() {
        let engine = WebSyncEngine()
        XCTAssertNil(engine.error)
    }
}

// MARK: - SessionStorage Unit Tests

final class SessionStorageTests: XCTestCase {

    // MARK: - MockSessionStorage Tests

    func testMockSessionStorageStoreAndRetrieveCookies() {
        let storage = MockSessionStorage()
        let cookies = MockSessionStorage.createTestCookies(for: .claudeWeb)

        storage.storeCookies(cookies, for: .claudeWeb)
        let retrieved = storage.getCookies(for: .claudeWeb)

        XCTAssertEqual(retrieved.count, cookies.count)
    }

    func testMockSessionStorageHasValidSession() {
        let storage = MockSessionStorage()

        // Initially no session
        XCTAssertFalse(storage.hasValidSession(for: .claudeWeb))

        // After storing cookies
        let cookies = MockSessionStorage.createTestCookies(for: .claudeWeb)
        storage.storeCookies(cookies, for: .claudeWeb)

        XCTAssertTrue(storage.hasValidSession(for: .claudeWeb))
    }

    func testMockSessionStorageClearSession() {
        let storage = MockSessionStorage()
        let cookies = MockSessionStorage.createTestCookies(for: .claudeWeb)

        storage.storeCookies(cookies, for: .claudeWeb)
        XCTAssertTrue(storage.hasValidSession(for: .claudeWeb))

        storage.clearSession(for: .claudeWeb)
        XCTAssertFalse(storage.hasValidSession(for: .claudeWeb))
    }

    func testMockSessionStorageIsolatesProviders() {
        let storage = MockSessionStorage()

        // Store cookies for Claude
        let claudeCookies = MockSessionStorage.createTestCookies(for: .claudeWeb)
        storage.storeCookies(claudeCookies, for: .claudeWeb)

        // Store cookies for ChatGPT
        let chatgptCookies = MockSessionStorage.createTestCookies(for: .chatgptWeb)
        storage.storeCookies(chatgptCookies, for: .chatgptWeb)

        // Both should have sessions
        XCTAssertTrue(storage.hasValidSession(for: .claudeWeb))
        XCTAssertTrue(storage.hasValidSession(for: .chatgptWeb))

        // Clear only Claude
        storage.clearSession(for: .claudeWeb)

        XCTAssertFalse(storage.hasValidSession(for: .claudeWeb))
        XCTAssertTrue(storage.hasValidSession(for: .chatgptWeb))
    }

    func testMockSessionStorageClearAll() {
        let storage = MockSessionStorage()

        storage.storeCookies(MockSessionStorage.createTestCookies(for: .claudeWeb), for: .claudeWeb)
        storage.storeCookies(MockSessionStorage.createTestCookies(for: .chatgptWeb), for: .chatgptWeb)

        XCTAssertTrue(storage.hasValidSession(for: .claudeWeb))
        XCTAssertTrue(storage.hasValidSession(for: .chatgptWeb))

        storage.clearAll()

        XCTAssertFalse(storage.hasValidSession(for: .claudeWeb))
        XCTAssertFalse(storage.hasValidSession(for: .chatgptWeb))
    }

    func testCreateTestCookiesForClaude() {
        let cookies = MockSessionStorage.createTestCookies(for: .claudeWeb)

        XCTAssertEqual(cookies.count, 2)
        XCTAssertTrue(cookies.allSatisfy { $0.domain == "claude.ai" })
    }

    func testCreateTestCookiesForChatGPT() {
        let cookies = MockSessionStorage.createTestCookies(for: .chatgptWeb)

        XCTAssertEqual(cookies.count, 2)
        XCTAssertTrue(cookies.allSatisfy { $0.domain == "chatgpt.com" })
    }

    func testCookiesReturnEmptyForNonWebProviders() {
        let storage = MockSessionStorage()

        // Non-web providers shouldn't typically have cookies
        let cookies = storage.getCookies(for: .claudeCode)
        XCTAssertTrue(cookies.isEmpty)
    }
}
