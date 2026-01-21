import XCTest
import GRDB
@testable import Retain

final class WorkflowSignatureRepositoryTests: XCTestCase {
    private var database: AppDatabase!
    private var conversationRepository: ConversationRepository!
    private var workflowRepository: WorkflowSignatureRepository!

    override func setUp() async throws {
        database = try AppDatabase.makeInMemory()
        conversationRepository = ConversationRepository(database: database)
        workflowRepository = WorkflowSignatureRepository(db: database)
    }

    override func tearDown() async throws {
        workflowRepository = nil
        conversationRepository = nil
        database = nil
    }

    func testUpsertAndFetchTopClusters() async throws {
        let convoA = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Summarize video",
            projectPath: "/Users/test/ProjectA",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 1
        )
        let convoB = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Summarize video",
            projectPath: "/Users/test/ProjectB",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 1
        )

        try conversationRepository.insert(convoA, messages: [
            Message(conversationId: convoA.id, role: .user, content: "Summarize this video.", timestamp: Date())
        ])
        try conversationRepository.insert(convoB, messages: [
            Message(conversationId: convoB.id, role: .user, content: "Summarize this video.", timestamp: Date())
        ])

        let signature = "summarize|summary|video"
        let now = Date()

        try await workflowRepository.upsert(
            WorkflowSignature(
                conversationId: convoA.id,
                signature: signature,
                action: "summarize",
                artifact: "summary",
                domains: "video",
                snippet: "Summarize this video.",
                createdAt: now,
                updatedAt: now
            )
        )

        try await workflowRepository.upsert(
            WorkflowSignature(
                conversationId: convoB.id,
                signature: signature,
                action: "summarize",
                artifact: "summary",
                domains: "video",
                snippet: "Summarize this video.",
                createdAt: now,
                updatedAt: now
            )
        )

        let clusters = try await workflowRepository.fetchTopClusters(limit: 1, sampleLimit: 2, minimumCount: 2)
        XCTAssertEqual(clusters.count, 1)
        let cluster = clusters[0]
        XCTAssertEqual(cluster.signature, signature)
        XCTAssertEqual(cluster.count, 2)
        XCTAssertEqual(cluster.distinctProjects, 2)
        XCTAssertEqual(cluster.samples.count, 2)
    }
}
