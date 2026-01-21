import XCTest
@testable import Retain

final class ClaudeWebSyncTests: XCTestCase {

    // MARK: - Response Parsing Tests

    func testParseOrganizationsResponse() throws {
        let json = MockAPIResponses.claudeOrganizations(orgId: "test-org-uuid", name: "My Organization")
        let data = try JSONSerialization.data(withJSONObject: json)

        let orgs = try JSONDecoder().decode([ClaudeWebSync.OrganizationsResponse].self, from: data)

        XCTAssertEqual(orgs.count, 1)
        XCTAssertEqual(orgs.first?.uuid, "test-org-uuid")
        XCTAssertEqual(orgs.first?.name, "My Organization")
    }

    func testParseConversationListResponse() throws {
        let json = MockAPIResponses.claudeConversationList(conversations: [
            (id: "conv-1", title: "First Conversation", created: "2024-01-01T10:00:00.000Z", updated: "2024-01-01T11:00:00.000Z"),
            (id: "conv-2", title: "Second Conversation", created: "2024-01-02T10:00:00.000Z", updated: "2024-01-02T11:00:00.000Z")
        ])
        let data = try JSONSerialization.data(withJSONObject: json)

        let conversations = try JSONDecoder().decode([ClaudeWebSync.ConversationsResponse].self, from: data)

        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].uuid, "conv-1")
        XCTAssertEqual(conversations[0].name, "First Conversation")
        XCTAssertEqual(conversations[1].uuid, "conv-2")
        XCTAssertEqual(conversations[1].name, "Second Conversation")
    }

    func testParseConversationDetailResponse() throws {
        let json = MockAPIResponses.claudeConversation(
            id: "conv-123",
            title: "Test Conversation",
            messages: [
                (uuid: "msg-1", text: "Hello, can you help me?", sender: "human", created: "2024-01-01T10:00:00.000Z"),
                (uuid: "msg-2", text: "Of course! How can I assist you today?", sender: "assistant", created: "2024-01-01T10:00:30.000Z"),
                (uuid: "msg-3", text: "I need help with Swift code.", sender: "human", created: "2024-01-01T10:01:00.000Z")
            ]
        )
        let data = try JSONSerialization.data(withJSONObject: json)

        let detail = try JSONDecoder().decode(ClaudeWebSync.ConversationDetailResponse.self, from: data)

        XCTAssertEqual(detail.uuid, "conv-123")
        XCTAssertEqual(detail.name, "Test Conversation")
        XCTAssertEqual(detail.chat_messages.count, 3)

        // Verify message content
        XCTAssertEqual(detail.chat_messages[0].uuid, "msg-1")
        XCTAssertEqual(detail.chat_messages[0].text, "Hello, can you help me?")
        XCTAssertEqual(detail.chat_messages[0].sender, "human")

        XCTAssertEqual(detail.chat_messages[1].sender, "assistant")
        XCTAssertEqual(detail.chat_messages[2].sender, "human")
    }

    func testParseEmptyConversationList() throws {
        let json: [[String: Any]] = []
        let data = try JSONSerialization.data(withJSONObject: json)

        let conversations = try JSONDecoder().decode([ClaudeWebSync.ConversationsResponse].self, from: data)

        XCTAssertTrue(conversations.isEmpty)
    }

    func testParseDateFormats() throws {
        // Test with fractional seconds
        let jsonWithFractional = MockAPIResponses.claudeConversationList(conversations: [
            (id: "conv-1", title: "Test", created: "2024-01-01T10:00:00.123Z", updated: "2024-01-01T11:00:00.456Z")
        ])
        let dataWithFractional = try JSONSerialization.data(withJSONObject: jsonWithFractional)
        let convWithFractional = try JSONDecoder().decode([ClaudeWebSync.ConversationsResponse].self, from: dataWithFractional)
        XCTAssertEqual(convWithFractional.first?.uuid, "conv-1")

        // Test without fractional seconds
        let jsonWithoutFractional = MockAPIResponses.claudeConversationList(conversations: [
            (id: "conv-2", title: "Test2", created: "2024-01-01T10:00:00Z", updated: "2024-01-01T11:00:00Z")
        ])
        let dataWithoutFractional = try JSONSerialization.data(withJSONObject: jsonWithoutFractional)
        let convWithoutFractional = try JSONDecoder().decode([ClaudeWebSync.ConversationsResponse].self, from: dataWithoutFractional)
        XCTAssertEqual(convWithoutFractional.first?.uuid, "conv-2")
    }

    // MARK: - Message Role Mapping Tests

    func testHumanSenderMapsToUserRole() throws {
        let json = MockAPIResponses.claudeConversation(
            id: "conv-123",
            title: "Test",
            messages: [
                (uuid: "msg-1", text: "User message", sender: "human", created: "2024-01-01T10:00:00.000Z")
            ]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ClaudeWebSync.ConversationDetailResponse.self, from: data)

        XCTAssertEqual(detail.chat_messages.first?.sender, "human")
    }

    func testAssistantSenderMapsToAssistantRole() throws {
        let json = MockAPIResponses.claudeConversation(
            id: "conv-123",
            title: "Test",
            messages: [
                (uuid: "msg-1", text: "Assistant message", sender: "assistant", created: "2024-01-01T10:00:00.000Z")
            ]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ClaudeWebSync.ConversationDetailResponse.self, from: data)

        XCTAssertEqual(detail.chat_messages.first?.sender, "assistant")
    }

    // MARK: - ConversationMeta Tests

    func testConversationMetaCreation() {
        let meta = ConversationMeta(
            id: "test-id",
            title: "Test Title",
            createdAt: Date(timeIntervalSince1970: 1704067200), // 2024-01-01 00:00:00
            updatedAt: Date(timeIntervalSince1970: 1704070800)  // 2024-01-01 01:00:00
        )

        XCTAssertEqual(meta.id, "test-id")
        XCTAssertEqual(meta.title, "Test Title")
        XCTAssertEqual(meta.createdAt.timeIntervalSince1970, 1704067200)
        XCTAssertEqual(meta.updatedAt.timeIntervalSince1970, 1704070800)
    }

    func testConversationMetaWithNilTitle() {
        let meta = ConversationMeta(
            id: "test-id",
            title: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        XCTAssertEqual(meta.id, "test-id")
        XCTAssertNil(meta.title)
    }

    // MARK: - Error Response Tests

    func testWebSyncErrorDescriptions() {
        XCTAssertEqual(
            WebSyncEngine.WebSyncError.notAuthenticated.errorDescription,
            "Not authenticated. Please sign in."
        )

        XCTAssertEqual(
            WebSyncEngine.WebSyncError.rateLimited(retryAfter: nil).errorDescription,
            "Rate limited. Please wait and try again."
        )

        XCTAssertEqual(
            WebSyncEngine.WebSyncError.sessionExpired.errorDescription,
            "Session expired. Please sign in again."
        )

        let parseError = WebSyncEngine.WebSyncError.parseError("Invalid JSON")
        XCTAssertEqual(parseError.errorDescription, "Parse error: Invalid JSON")

        let networkError = WebSyncEngine.WebSyncError.networkError(URLError(.badServerResponse))
        XCTAssertTrue(networkError.errorDescription?.contains("Network error") ?? false)
    }
}
