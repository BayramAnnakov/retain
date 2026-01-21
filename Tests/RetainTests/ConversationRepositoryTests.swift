import XCTest
import GRDB
@testable import Retain

final class ConversationRepositoryTests: XCTestCase {
    var database: AppDatabase!
    var repository: ConversationRepository!

    override func setUp() async throws {
        database = try AppDatabase.makeInMemory()
        repository = ConversationRepository(database: database)
    }

    override func tearDown() async throws {
        repository = nil
        database = nil
    }

    // MARK: - Helper Methods

    private func makeConversation(
        provider: Provider = .claudeCode,
        title: String = "Test Conversation",
        externalId: String? = nil
    ) -> Conversation {
        Conversation(
            id: UUID(),
            provider: provider,
            sourceType: provider == .claudeCode ? .cli : .web,
            externalId: externalId ?? UUID().uuidString,
            title: title,
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 0
        )
    }

    private func makeMessage(conversationId: UUID, role: Role = .user, content: String = "Test") -> Message {
        Message(
            id: UUID(),
            conversationId: conversationId,
            role: role,
            content: content,
            timestamp: Date()
        )
    }

    // MARK: - Insert Tests

    func testInsertConversation() throws {
        let conversation = makeConversation()
        let messages = [
            makeMessage(conversationId: conversation.id, content: "Hello"),
            makeMessage(conversationId: conversation.id, role: .assistant, content: "Hi there!")
        ]

        try repository.insert(conversation, messages: messages)

        let fetched = try repository.fetch(id: conversation.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.messageCount, 2)
    }

    func testUpsertNewConversation() throws {
        let conversation = makeConversation(externalId: "unique-id")
        let messages = [makeMessage(conversationId: conversation.id)]

        _ = try repository.upsert(conversation, messages: messages)

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 1)
    }

    func testUpsertExistingConversation() throws {
        let externalId = "persistent-id"
        let conversation1 = makeConversation(title: "Original Title", externalId: externalId)
        let messages1 = [makeMessage(conversationId: conversation1.id, content: "Original")]

        _ = try repository.upsert(conversation1, messages: messages1)

        // Upsert with same external ID but different title
        let conversation2 = makeConversation(title: "Updated Title", externalId: externalId)
        let messages2 = [
            makeMessage(conversationId: conversation2.id, content: "Updated 1"),
            makeMessage(conversationId: conversation2.id, content: "Updated 2")
        ]

        _ = try repository.upsert(conversation2, messages: messages2)

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 1, "Should update existing instead of inserting new")
        XCTAssertEqual(all.first?.title, "Updated Title")
        XCTAssertEqual(all.first?.messageCount, 2)
    }

    // MARK: - Fetch Tests

    func testFetchAll() throws {
        // Insert multiple conversations
        for i in 1...5 {
            let conv = makeConversation(title: "Conversation \(i)")
            try repository.insert(conv, messages: [])
        }

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 5)
    }

    func testFetchByProvider() throws {
        // Insert conversations from different providers
        try repository.insert(makeConversation(provider: .claudeCode, title: "CC 1"), messages: [])
        try repository.insert(makeConversation(provider: .claudeCode, title: "CC 2"), messages: [])
        try repository.insert(makeConversation(provider: .codex, title: "Codex 1"), messages: [])

        let claudeCodeConvs = try repository.fetch(provider: .claudeCode)
        let codexConvs = try repository.fetch(provider: .codex)

        XCTAssertEqual(claudeCodeConvs.count, 2)
        XCTAssertEqual(codexConvs.count, 1)
    }

    func testFetchById() throws {
        let conversation = makeConversation(title: "Specific Conversation")
        try repository.insert(conversation, messages: [])

        let fetched = try repository.fetch(id: conversation.id)

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, conversation.id)
        XCTAssertEqual(fetched?.title, "Specific Conversation")
    }

    func testFetchByIdNotFound() throws {
        let fetched = try repository.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testFetchMessages() throws {
        let conversation = makeConversation()
        let messages = [
            makeMessage(conversationId: conversation.id, content: "First"),
            makeMessage(conversationId: conversation.id, content: "Second"),
            makeMessage(conversationId: conversation.id, content: "Third")
        ]

        try repository.insert(conversation, messages: messages)

        let fetchedMessages = try repository.fetchMessages(conversationId: conversation.id)

        XCTAssertEqual(fetchedMessages.count, 3)
    }

    // MARK: - Search Tests

    func testSearchMessages() throws {
        let conversation = makeConversation(title: "Swift Help")
        let messages = [
            makeMessage(conversationId: conversation.id, content: "How do I use async/await in Swift?"),
            makeMessage(conversationId: conversation.id, role: .assistant, content: "To use async/await, mark your function with async keyword.")
        ]

        try repository.insert(conversation, messages: messages)

        let results = try repository.searchMessages(query: "async")

        XCTAssertGreaterThan(results.count, 0)
        XCTAssertTrue(results.allSatisfy { $0.0.content.lowercased().contains("async") })
    }

    func testSearchConversations() throws {
        try repository.insert(makeConversation(title: "SwiftUI Development"), messages: [])
        try repository.insert(makeConversation(title: "Python Scripting"), messages: [])
        try repository.insert(makeConversation(title: "Swift Package Manager"), messages: [])

        let results = try repository.searchConversations(query: "Swift")

        XCTAssertEqual(results.count, 2)
    }

    func testSearchNoResults() throws {
        try repository.insert(makeConversation(title: "Python Help"), messages: [])

        let results = try repository.searchMessages(query: "nonexistent query xyz")

        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Delete Tests

    func testDeleteById() throws {
        let conversation = makeConversation()
        try repository.insert(conversation, messages: [])

        try repository.delete(id: conversation.id)

        let fetched = try repository.fetch(id: conversation.id)
        XCTAssertNil(fetched)
    }

    func testDeleteByProvider() throws {
        try repository.insert(makeConversation(provider: .claudeCode), messages: [])
        try repository.insert(makeConversation(provider: .claudeCode), messages: [])
        try repository.insert(makeConversation(provider: .codex), messages: [])

        try repository.delete(provider: .claudeCode)

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.provider, .codex)
    }

    // MARK: - Stats Tests

    func testCountByProvider() throws {
        try repository.insert(makeConversation(provider: .claudeCode), messages: [])
        try repository.insert(makeConversation(provider: .claudeCode), messages: [])
        try repository.insert(makeConversation(provider: .claudeCode), messages: [])
        try repository.insert(makeConversation(provider: .codex), messages: [])

        let stats = try repository.countByProvider()

        XCTAssertEqual(stats[.claudeCode], 3)
        XCTAssertEqual(stats[.codex], 1)
    }

    func testTotalMessageCount() throws {
        let conv1 = makeConversation()
        let conv2 = makeConversation()

        try repository.insert(conv1, messages: [
            makeMessage(conversationId: conv1.id),
            makeMessage(conversationId: conv1.id)
        ])
        try repository.insert(conv2, messages: [
            makeMessage(conversationId: conv2.id),
            makeMessage(conversationId: conv2.id),
            makeMessage(conversationId: conv2.id)
        ])

        let total = try repository.totalMessageCount()
        XCTAssertEqual(total, 5)
    }

    // MARK: - Ordering Tests

    func testFetchAllOrderedByUpdateTime() throws {
        // Insert conversations with different update times
        var conv1 = makeConversation(title: "Old")
        conv1.updatedAt = Date(timeIntervalSince1970: 1000)

        var conv2 = makeConversation(title: "Middle")
        conv2.updatedAt = Date(timeIntervalSince1970: 2000)

        var conv3 = makeConversation(title: "Recent")
        conv3.updatedAt = Date(timeIntervalSince1970: 3000)

        try repository.insert(conv1, messages: [])
        try repository.insert(conv2, messages: [])
        try repository.insert(conv3, messages: [])

        let all = try repository.fetchAll()

        // Should be ordered by updatedAt descending
        XCTAssertEqual(all[0].title, "Recent")
        XCTAssertEqual(all[1].title, "Middle")
        XCTAssertEqual(all[2].title, "Old")
    }
}
