import XCTest
import GRDB
@testable import Retain

final class DatabaseTests: XCTestCase {
    var database: AppDatabase!

    override func setUp() async throws {
        database = try AppDatabase.makeInMemory()
    }

    override func tearDown() async throws {
        database = nil
    }

    // MARK: - Schema Tests

    func testDatabaseInitialization() throws {
        // Database should initialize without errors
        XCTAssertNotNil(database)
        XCTAssertNotNil(database.dbWriter)
    }

    func testConversationsTableExists() throws {
        try database.read { db in
            let exists = try db.tableExists("conversations")
            XCTAssertTrue(exists, "conversations table should exist")
        }
    }

    func testMessagesTableExists() throws {
        try database.read { db in
            let exists = try db.tableExists("messages")
            XCTAssertTrue(exists, "messages table should exist")
        }
    }

    func testLearningsTableExists() throws {
        try database.read { db in
            let exists = try db.tableExists("learnings")
            XCTAssertTrue(exists, "learnings table should exist")
        }
    }

    func testWorkflowSignaturesTableExists() throws {
        try database.read { db in
            let exists = try db.tableExists("workflow_signatures")
            XCTAssertTrue(exists, "workflow_signatures table should exist")
        }
    }

    func testFTSTablesExist() throws {
        try database.read { db in
            let messagesFTS = try db.tableExists("messages_fts")
            let conversationsFTS = try db.tableExists("conversations_fts")
            XCTAssertTrue(messagesFTS, "messages_fts table should exist")
            XCTAssertTrue(conversationsFTS, "conversations_fts table should exist")
        }
    }

    // MARK: - Basic CRUD Tests

    func testInsertConversation() throws {
        let conversation = Conversation(
            id: UUID(),
            provider: .claudeCode,
            sourceType: .cli,
            externalId: "test-session",
            title: "Test Conversation",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 0
        )

        try database.write { db in
            var conv = conversation
            try conv.insert(db)
        }

        let fetched = try database.read { db in
            try Conversation.fetchOne(db, key: conversation.id)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test Conversation")
        XCTAssertEqual(fetched?.provider, .claudeCode)
    }

    func testInsertMessage() throws {
        // First insert a conversation
        let conversationId = UUID()
        let conversation = Conversation(
            id: conversationId,
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 0
        )

        try database.write { db in
            var conv = conversation
            try conv.insert(db)
        }

        // Then insert a message
        let messageId = UUID()
        let message = Message(
            id: messageId,
            conversationId: conversationId,
            role: .user,
            content: "Hello, world!",
            timestamp: Date()
        )

        try database.write { db in
            var msg = message
            try msg.insert(db)
        }

        let fetched = try database.read { db in
            try Message.fetchOne(db, key: messageId)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.content, "Hello, world!")
        XCTAssertEqual(fetched?.role, .user)
    }

    func testInsertLearning() throws {
        // First insert conversation and message
        let conversationId = UUID()
        let messageId = UUID()

        try database.write { db in
            var conv = Conversation(
                id: conversationId,
                provider: .claudeCode,
                sourceType: .cli,
                title: "Test",
                createdAt: Date(),
                updatedAt: Date(),
                messageCount: 1
            )
            try conv.insert(db)

            var msg = Message(
                id: messageId,
                conversationId: conversationId,
                role: .user,
                content: "Test message",
                timestamp: Date()
            )
            try msg.insert(db)
        }

        // Insert learning
        let learningId = UUID()
        let learning = Learning(
            id: learningId,
            conversationId: conversationId,
            messageId: messageId,
            type: .correction,
            pattern: "no, use X",
            extractedRule: "Use X instead of Y",
            confidence: 0.9,
            context: "Test context",
            status: .pending,
            scope: .global
        )

        try database.write { db in
            var l = learning
            try l.insert(db)
        }

        let fetched = try database.read { db in
            try Learning.fetchOne(db, key: learningId)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.extractedRule, "Use X instead of Y")
        XCTAssertEqual(fetched?.status, .pending)
        XCTAssertEqual(fetched?.confidence, 0.9)
    }

    // MARK: - Cascade Delete Tests

    func testCascadeDeleteMessages() throws {
        let conversationId = UUID()

        // Insert conversation with messages
        try database.write { db in
            var conv = Conversation(
                id: conversationId,
                provider: .claudeCode,
                sourceType: .cli,
                title: "Test",
                createdAt: Date(),
                updatedAt: Date(),
                messageCount: 2
            )
            try conv.insert(db)

            var msg1 = Message(
                id: UUID(),
                conversationId: conversationId,
                role: .user,
                content: "Message 1",
                timestamp: Date()
            )
            try msg1.insert(db)

            var msg2 = Message(
                id: UUID(),
                conversationId: conversationId,
                role: .assistant,
                content: "Message 2",
                timestamp: Date()
            )
            try msg2.insert(db)
        }

        // Verify messages exist
        let countBefore = try database.read { db in
            try Message.filter(Message.Columns.conversationId == conversationId).fetchCount(db)
        }
        XCTAssertEqual(countBefore, 2)

        // Delete conversation
        try database.write { db in
            try Conversation.deleteOne(db, key: conversationId)
        }

        // Messages should be cascade deleted
        let countAfter = try database.read { db in
            try Message.filter(Message.Columns.conversationId == conversationId).fetchCount(db)
        }
        XCTAssertEqual(countAfter, 0)
    }

    // MARK: - FTS Tests

    func testFullTextSearchMessages() throws {
        let conversationId = UUID()

        try database.write { db in
            var conv = Conversation(
                id: conversationId,
                provider: .claudeCode,
                sourceType: .cli,
                title: "Swift Development",
                createdAt: Date(),
                updatedAt: Date(),
                messageCount: 2
            )
            try conv.insert(db)

            var msg1 = Message(
                id: UUID(),
                conversationId: conversationId,
                role: .user,
                content: "How do I implement async/await in Swift?",
                timestamp: Date()
            )
            try msg1.insert(db)

            var msg2 = Message(
                id: UUID(),
                conversationId: conversationId,
                role: .assistant,
                content: "You can use the async keyword to mark functions as asynchronous.",
                timestamp: Date()
            )
            try msg2.insert(db)
        }

        // Search for "async"
        let results = try database.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: "async")
            let sql = """
                SELECT messages.*
                FROM messages
                JOIN messages_fts ON messages_fts.rowid = messages.rowid
                WHERE messages_fts MATCH ?
                ORDER BY rank
                """
            return try Message.fetchAll(db, sql: sql, arguments: [pattern])
        }

        XCTAssertEqual(results.count, 2, "Should find 2 messages containing 'async'")
    }
}
