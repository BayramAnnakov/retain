import XCTest
import GRDB
@testable import Retain

final class LearningRepositoryTests: XCTestCase {
    var database: AppDatabase!
    var repository: LearningRepository!
    var conversationId: UUID!
    var messageId: UUID!

    override func setUp() async throws {
        database = try AppDatabase.makeInMemory()
        repository = LearningRepository(database: database)

        // Create prerequisite conversation and message
        conversationId = UUID()
        messageId = UUID()

        try database.write { db in
            var conv = Conversation(
                id: conversationId,
                provider: .claudeCode,
                sourceType: .cli,
                title: "Test Conversation",
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
    }

    override func tearDown() async throws {
        repository = nil
        database = nil
    }

    // MARK: - Helper Methods

    private func makeLearning(
        type: LearningType = .correction,
        status: LearningStatus = .pending,
        scope: LearningScope = .global,
        confidence: Float = 0.9
    ) -> Learning {
        Learning(
            id: UUID(),
            conversationId: conversationId,
            messageId: messageId,
            type: type,
            pattern: "no, use X",
            extractedRule: "Use X instead of Y",
            confidence: confidence,
            context: "Test context",
            status: status,
            scope: scope
        )
    }

    // MARK: - Insert Tests

    func testInsertLearning() throws {
        let learning = makeLearning()

        try repository.insert(learning)

        let fetched = try repository.fetch(id: learning.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.extractedRule, "Use X instead of Y")
    }

    func testInsertMultipleLearnings() throws {
        let learnings = [
            makeLearning(),
            makeLearning(),
            makeLearning()
        ]

        try repository.insert(learnings)

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - Fetch Tests

    func testFetchAll() throws {
        for _ in 1...5 {
            try repository.insert(makeLearning())
        }

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 5)
    }

    func testFetchByStatus() throws {
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .approved))

        let pending = try repository.fetch(status: .pending)
        let approved = try repository.fetch(status: .approved)

        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(approved.count, 1)
    }

    func testFetchPending() throws {
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .approved))
        try repository.insert(makeLearning(status: .rejected))

        let pending = try repository.fetchPending()

        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending.allSatisfy { $0.status == .pending })
    }

    func testFetchApproved() throws {
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .approved))
        try repository.insert(makeLearning(status: .approved))

        let approved = try repository.fetchApproved()

        XCTAssertEqual(approved.count, 2)
        XCTAssertTrue(approved.allSatisfy { $0.status == .approved })
    }

    func testFetchByConversationId() throws {
        try repository.insert(makeLearning())
        try repository.insert(makeLearning())

        // Create learning for different conversation
        let otherConvId = UUID()
        let otherMsgId = UUID()
        try database.write { db in
            var conv = Conversation(
                id: otherConvId,
                provider: .codex,
                sourceType: .cli,
                title: "Other",
                createdAt: Date(),
                updatedAt: Date(),
                messageCount: 1
            )
            try conv.insert(db)

            var msg = Message(
                id: otherMsgId,
                conversationId: otherConvId,
                role: .user,
                content: "Other message",
                timestamp: Date()
            )
            try msg.insert(db)

            var learning = Learning(
                id: UUID(),
                conversationId: otherConvId,
                messageId: otherMsgId,
                type: .correction,
                pattern: "test",
                extractedRule: "test rule",
                confidence: 0.8
            )
            try learning.insert(db)
        }

        let learnings = try repository.fetch(conversationId: conversationId)

        XCTAssertEqual(learnings.count, 2)
    }

    func testFetchById() throws {
        let learning = makeLearning()
        try repository.insert(learning)

        let fetched = try repository.fetch(id: learning.id)

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, learning.id)
    }

    func testCountPending() throws {
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .approved))

        let count = try repository.countPending()

        XCTAssertEqual(count, 3)
    }

    func testCountByStatus() throws {
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .approved))
        try repository.insert(makeLearning(status: .rejected))

        let counts = try repository.countByStatus()

        XCTAssertEqual(counts[.pending], 2)
        XCTAssertEqual(counts[.approved], 1)
        XCTAssertEqual(counts[.rejected], 1)
    }

    // MARK: - Update Tests

    func testUpdateLearning() throws {
        var learning = makeLearning()
        try repository.insert(learning)

        learning.extractedRule = "Updated rule"
        try repository.update(learning)

        let fetched = try repository.fetch(id: learning.id)
        XCTAssertEqual(fetched?.extractedRule, "Updated rule")
    }

    func testApproveLearning() throws {
        let learning = makeLearning(status: .pending)
        try repository.insert(learning)

        try repository.approve(id: learning.id)

        let fetched = try repository.fetch(id: learning.id)
        XCTAssertEqual(fetched?.status, .approved)
        XCTAssertNotNil(fetched?.reviewedAt)
    }

    func testRejectLearning() throws {
        let learning = makeLearning(status: .pending)
        try repository.insert(learning)

        try repository.reject(id: learning.id)

        let fetched = try repository.fetch(id: learning.id)
        XCTAssertEqual(fetched?.status, .rejected)
        XCTAssertNotNil(fetched?.reviewedAt)
    }

    func testApproveAllLearnings() throws {
        let learning1 = makeLearning(status: .pending)
        let learning2 = makeLearning(status: .pending)
        let learning3 = makeLearning(status: .pending)

        try repository.insert(learning1)
        try repository.insert(learning2)
        try repository.insert(learning3)

        try repository.approveAll(ids: [learning1.id, learning2.id])

        let approved = try repository.fetchApproved()
        let pending = try repository.fetchPending()

        XCTAssertEqual(approved.count, 2)
        XCTAssertEqual(pending.count, 1)
    }

    // MARK: - Delete Tests

    func testDeleteById() throws {
        let learning = makeLearning()
        try repository.insert(learning)

        try repository.delete(id: learning.id)

        let fetched = try repository.fetch(id: learning.id)
        XCTAssertNil(fetched)
    }

    func testDeleteRejected() throws {
        try repository.insert(makeLearning(status: .pending))
        try repository.insert(makeLearning(status: .approved))
        try repository.insert(makeLearning(status: .rejected))
        try repository.insert(makeLearning(status: .rejected))

        try repository.deleteRejected()

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertFalse(all.contains { $0.status == .rejected })
    }

    func testDeleteByConversationId() throws {
        try repository.insert(makeLearning())
        try repository.insert(makeLearning())

        try repository.delete(conversationId: conversationId)

        let learnings = try repository.fetch(conversationId: conversationId)
        XCTAssertEqual(learnings.count, 0)
    }

    // MARK: - Search Tests

    func testSearchByPattern() throws {
        var learning1 = makeLearning()
        learning1.pattern = "no, use async/await"
        try repository.insert(learning1)

        var learning2 = makeLearning()
        learning2.pattern = "please don't use callbacks"
        try repository.insert(learning2)

        let results = try repository.search(query: "async")

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.pattern.contains("async") ?? false)
    }

    func testSearchByRule() throws {
        var learning1 = makeLearning()
        learning1.extractedRule = "Always use SwiftUI"
        try repository.insert(learning1)

        var learning2 = makeLearning()
        learning2.extractedRule = "Never use force unwrap"
        try repository.insert(learning2)

        let results = try repository.search(query: "SwiftUI")

        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Export Tests

    func testFetchApprovedGroupedByScope() throws {
        var global1 = makeLearning(status: .approved, scope: .global)
        var global2 = makeLearning(status: .approved, scope: .global)
        var project = makeLearning(status: .approved, scope: .project)

        try repository.insert(global1)
        try repository.insert(global2)
        try repository.insert(project)

        let grouped = try repository.fetchApprovedGroupedByScope()

        XCTAssertEqual(grouped[.global]?.count, 2)
        XCTAssertEqual(grouped[.project]?.count, 1)
    }

    func testFetchApprovedGroupedByType() throws {
        var correction = makeLearning(type: .correction, status: .approved)
        var positive = makeLearning(type: .positive, status: .approved)
        var implicit = makeLearning(type: .implicit, status: .approved)

        try repository.insert(correction)
        try repository.insert(positive)
        try repository.insert(implicit)

        let grouped = try repository.fetchApprovedGroupedByType()

        XCTAssertEqual(grouped[.correction]?.count, 1)
        XCTAssertEqual(grouped[.positive]?.count, 1)
        XCTAssertEqual(grouped[.implicit]?.count, 1)
    }
}
