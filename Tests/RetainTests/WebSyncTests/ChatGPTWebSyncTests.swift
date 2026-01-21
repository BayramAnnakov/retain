import XCTest
@testable import Retain

final class ChatGPTWebSyncTests: XCTestCase {

    // MARK: - Response Parsing Tests

    func testParseSessionResponse() throws {
        let json = MockAPIResponses.chatgptSession(userId: "user-abc123", email: "test@example.com")
        let data = try JSONSerialization.data(withJSONObject: json)

        let session = try JSONDecoder().decode(ChatGPTWebSync.SessionResponse.self, from: data)

        XCTAssertNotNil(session.user)
        XCTAssertEqual(session.user?.id, "user-abc123")
        XCTAssertEqual(session.user?.email, "test@example.com")
        XCTAssertEqual(session.user?.name, "Test User")
        XCTAssertEqual(session.accessToken, "test-access-token")
    }

    func testParseConversationListResponse() throws {
        let now = Date().timeIntervalSince1970
        let json = MockAPIResponses.chatgptConversationList(conversations: [
            (id: "conv-1", title: "Swift Programming Help", createTime: now - 3600, updateTime: now - 1800),
            (id: "conv-2", title: "Python Data Analysis", createTime: now - 7200, updateTime: now - 3600)
        ])
        let data = try JSONSerialization.data(withJSONObject: json)

        let response = try JSONDecoder().decode(ChatGPTWebSync.ConversationsListResponse.self, from: data)

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].id, "conv-1")
        XCTAssertEqual(response.items[0].title, "Swift Programming Help")
        XCTAssertEqual(response.items[1].id, "conv-2")
        XCTAssertEqual(response.items[1].title, "Python Data Analysis")
        XCTAssertEqual(response.limit, 20)
        XCTAssertEqual(response.offset, 0)
    }

    func testParseConversationDetailResponse() throws {
        let now = Date().timeIntervalSince1970
        let json = MockAPIResponses.chatgptConversation(
            title: "Test Conversation",
            messages: [
                (id: "msg-1", role: "user", text: "Hello, can you help me?", createTime: now - 300),
                (id: "msg-2", role: "assistant", text: "Of course! What do you need help with?", createTime: now - 290),
                (id: "msg-3", role: "user", text: "I need help with SwiftUI.", createTime: now - 200)
            ]
        )
        let data = try JSONSerialization.data(withJSONObject: json)

        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        XCTAssertEqual(detail.title, "Test Conversation")
        XCTAssertFalse(detail.mapping.isEmpty)
        XCTAssertEqual(detail.mapping.count, 3)
    }

    func testParsePaginatedConversationList() throws {
        let now = Date().timeIntervalSince1970
        let json = MockAPIResponses.chatgptConversationList(
            conversations: [
                (id: "conv-21", title: "Conversation 21", createTime: now, updateTime: now)
            ],
            total: 50,
            offset: 20
        )
        let data = try JSONSerialization.data(withJSONObject: json)

        let response = try JSONDecoder().decode(ChatGPTWebSync.ConversationsListResponse.self, from: data)

        XCTAssertEqual(response.total, 50)
        XCTAssertEqual(response.offset, 20)
        XCTAssertEqual(response.limit, 20)
    }

    func testParseEmptyConversationList() throws {
        let json = MockAPIResponses.chatgptConversationList(conversations: [], total: 0)
        let data = try JSONSerialization.data(withJSONObject: json)

        let response = try JSONDecoder().decode(ChatGPTWebSync.ConversationsListResponse.self, from: data)

        XCTAssertTrue(response.items.isEmpty)
        XCTAssertEqual(response.total, 0)
    }

    // MARK: - Message Role Mapping Tests

    func testUserRoleMapping() throws {
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [(id: "msg-1", role: "user", text: "User message", createTime: Date().timeIntervalSince1970)]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        let message = detail.mapping.values.first?.message
        XCTAssertEqual(message?.author.role, "user")
    }

    func testAssistantRoleMapping() throws {
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [(id: "msg-1", role: "assistant", text: "Assistant message", createTime: Date().timeIntervalSince1970)]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        let message = detail.mapping.values.first?.message
        XCTAssertEqual(message?.author.role, "assistant")
    }

    func testSystemRoleMapping() throws {
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [(id: "msg-1", role: "system", text: "System message", createTime: Date().timeIntervalSince1970)]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        let message = detail.mapping.values.first?.message
        XCTAssertEqual(message?.author.role, "system")
    }

    func testToolRoleMapping() throws {
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [(id: "msg-1", role: "tool", text: "Tool output", createTime: Date().timeIntervalSince1970)]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        let message = detail.mapping.values.first?.message
        XCTAssertEqual(message?.author.role, "tool")
    }

    // MARK: - Content Extraction Tests

    func testContentPartsExtraction() throws {
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [(id: "msg-1", role: "user", text: "Hello world!", createTime: Date().timeIntervalSince1970)]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        let message = detail.mapping.values.first?.message
        XCTAssertNotNil(message?.content.parts)
        XCTAssertEqual(message?.content.parts?.first?.text, "Hello world!")
    }

    func testStringOrArrayDecoding() throws {
        // Test string part
        let stringPart = ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent.Content.StringOrArray.string("test")
        XCTAssertEqual(stringPart.text, "test")

        // Test object part (should return nil for text)
        let objectPart = ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent.Content.StringOrArray.object([:])
        XCTAssertNil(objectPart.text)
    }

    // MARK: - Mapping Tree Structure Tests

    func testMappingNodeStructure() throws {
        let now = Date().timeIntervalSince1970
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [
                (id: "msg-1", role: "user", text: "First", createTime: now),
                (id: "msg-2", role: "assistant", text: "Second", createTime: now + 1)
            ]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        // Verify parent-child relationships exist
        let node0 = detail.mapping["node-0"]
        let node1 = detail.mapping["node-1"]

        XCTAssertNotNil(node0)
        XCTAssertNotNil(node1)

        // First node should have no parent (or null parent)
        // Second node should reference first as parent
        XCTAssertEqual(node1?.parent, "node-0")

        // First node should have second as child
        XCTAssertTrue(node0?.children?.contains("node-1") ?? false)
    }

    func testCurrentNodeTracking() throws {
        let now = Date().timeIntervalSince1970
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [
                (id: "msg-1", role: "user", text: "First", createTime: now),
                (id: "msg-2", role: "assistant", text: "Second", createTime: now + 1),
                (id: "msg-3", role: "user", text: "Third", createTime: now + 2)
            ]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        // Current node should be the last message
        XCTAssertEqual(detail.current_node, "node-2")
    }

    // MARK: - Model Metadata Tests

    func testModelSlugExtraction() throws {
        let json = MockAPIResponses.chatgptConversation(
            title: "Test",
            messages: [(id: "msg-1", role: "assistant", text: "Response", createTime: Date().timeIntervalSince1970)]
        )
        let data = try JSONSerialization.data(withJSONObject: json)
        let detail = try JSONDecoder().decode(ChatGPTWebSync.ConversationDetailResponse.self, from: data)

        let message = detail.mapping.values.first?.message
        XCTAssertEqual(message?.metadata?.model_slug, "gpt-4")
    }

    // MARK: - Timestamp Tests

    func testTimestampConversion() throws {
        let expectedTime: TimeInterval = 1704067200 // 2024-01-01 00:00:00 UTC
        let json = MockAPIResponses.chatgptConversationList(conversations: [
            (id: "conv-1", title: "Test", createTime: expectedTime, updateTime: expectedTime + 3600)
        ])
        let data = try JSONSerialization.data(withJSONObject: json)

        let response = try JSONDecoder().decode(ChatGPTWebSync.ConversationsListResponse.self, from: data)

        XCTAssertEqual(response.items.first?.create_time, expectedTime)
        XCTAssertEqual(response.items.first?.update_time, expectedTime + 3600)
    }

    // MARK: - AnyCodable Tests

    func testAnyCodableString() throws {
        let json: [String: Any] = ["value": "test string"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode([String: ChatGPTWebSync.AnyCodable].self, from: data)

        XCTAssertEqual(decoded["value"]?.value as? String, "test string")
    }

    func testAnyCodableInt() throws {
        let json: [String: Any] = ["value": 42]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode([String: ChatGPTWebSync.AnyCodable].self, from: data)

        XCTAssertEqual(decoded["value"]?.value as? Int, 42)
    }

    func testAnyCodableBool() throws {
        let json: [String: Any] = ["value": true]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode([String: ChatGPTWebSync.AnyCodable].self, from: data)

        XCTAssertEqual(decoded["value"]?.value as? Bool, true)
    }

    func testAnyCodableDouble() throws {
        let json: [String: Any] = ["value": 3.14]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode([String: ChatGPTWebSync.AnyCodable].self, from: data)

        XCTAssertEqual(decoded["value"]?.value as? Double, 3.14)
    }
}
