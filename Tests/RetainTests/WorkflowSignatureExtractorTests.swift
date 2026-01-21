import XCTest
@testable import Retain

final class WorkflowSignatureExtractorTests: XCTestCase {
    private var extractor: WorkflowSignatureExtractor!

    override func setUp() async throws {
        extractor = WorkflowSignatureExtractor()
    }

    func testExtractsSignatureFromConversation() {
        let conversation = Conversation(
            provider: .claudeWeb,
            sourceType: .web,
            title: "Summarize video",
            previewText: "Summarize this video and include key timestamps.",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 1
        )

        let messages = [
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "Summarize this video and include key timestamps.",
                timestamp: Date()
            )
        ]

        let candidate = extractor.extractSignature(conversation: conversation, messages: messages)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.action, "summarize")
        XCTAssertEqual(candidate?.artifact, "timestamps")
        XCTAssertEqual(candidate?.signature, "summarize|timestamps|video")
        XCTAssertTrue(candidate?.domains.contains("video") == true)
    }

    func testClassifiesWarmupAsPriming() {
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Warmup",
            previewText: "Warmup",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 1
        )

        let messages = [
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "Warmup",
                timestamp: Date()
            )
        ]

        let candidate = extractor.extractSignature(conversation: conversation, messages: messages)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.action, "prime")
        XCTAssertEqual(candidate?.artifact, "context")
        XCTAssertEqual(candidate?.signature, "prime|context|setup")
    }

    func testFiltersGenericQuestion() {
        let conversation = Conversation(
            provider: .chatgptWeb,
            sourceType: .web,
            title: "What is tmux?",
            previewText: "What is tmux and what is it used for?",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 1
        )

        let messages = [
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "What is tmux and what is it used for in the context of coding agents?",
                timestamp: Date()
            )
        ]

        let candidate = extractor.extractSignature(conversation: conversation, messages: messages)
        XCTAssertNil(candidate)
    }
}
