import XCTest
@testable import Retain

/// Unit tests for GeminiLearningExtractor
final class GeminiLearningExtractorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockGeminiURLProtocol.reset()
    }

    override func tearDown() {
        MockGeminiURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Availability Tests

    func testIsAvailableWhenClientConfigured() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)
        let available = await extractor.isAvailable

        XCTAssertTrue(available)
    }

    func testIsNotAvailableWithNoClient() async {
        let extractor = await GeminiLearningExtractor()
        let available = await extractor.isAvailable

        XCTAssertFalse(available)
    }

    func testIsNotAvailableAfterClearingClient() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)

        // Clear the client
        await extractor.updateConfiguration(client: nil, minConfidence: 0.7)
        let available = await extractor.isAvailable

        XCTAssertFalse(available)
    }

    // MARK: - Extraction Success Tests

    func testExtractsLearningsFromConversation() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let config = GeminiLearningExtractor.Configuration(minConfidence: 0.5)
        let extractor = await GeminiLearningExtractor(client: client, configuration: config)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.learnings([
                (rule: "Use TypeScript for all code examples", type: "positive", confidence: 0.9),
                (rule: "Avoid emojis in responses", type: "correction", confidence: 0.85)
            ])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].rule, "Use TypeScript for all code examples")
        XCTAssertEqual(candidates[0].type, .positive)
        XCTAssertEqual(candidates[0].confidence, 0.9, accuracy: 0.01)
        XCTAssertEqual(candidates[0].pattern, "gemini")
    }

    func testFiltersLowConfidenceLearnings() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        // Set high confidence threshold
        let config = GeminiLearningExtractor.Configuration(minConfidence: 0.8)
        let extractor = await GeminiLearningExtractor(client: client, configuration: config)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.learnings([
                (rule: "High confidence rule", type: "positive", confidence: 0.9),
                (rule: "Low confidence rule", type: "implicit", confidence: 0.5),
                (rule: "Medium confidence rule", type: "correction", confidence: 0.75)
            ])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        // Only the high confidence one should pass
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].rule, "High confidence rule")
    }

    func testLimitsToMaxLearnings() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let config = GeminiLearningExtractor.Configuration(minConfidence: 0.5, maxLearnings: 2)
        let extractor = await GeminiLearningExtractor(client: client, configuration: config)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.learnings([
                (rule: "Rule 1", type: "positive", confidence: 0.9),
                (rule: "Rule 2", type: "correction", confidence: 0.8),
                (rule: "Rule 3", type: "implicit", confidence: 0.7),
                (rule: "Rule 4", type: "positive", confidence: 0.6)
            ])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        // Should be limited to maxLearnings
        XCTAssertLessThanOrEqual(candidates.count, 2)
    }

    // MARK: - Empty/Error Response Tests

    func testReturnsEmptyForNoMessages() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)

        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Empty conversation"
        )
        let messages: [Message] = []

        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        XCTAssertEqual(candidates.count, 0)
    }

    func testReturnsEmptyForNoClient() async {
        let extractor = await GeminiLearningExtractor()

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        XCTAssertEqual(candidates.count, 0)
    }

    func testHandlesEmptyGeminiResponse() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.emptyLearnings()
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        XCTAssertEqual(candidates.count, 0)
    }

    func testHandlesNetworkError() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            throw URLError(.notConnectedToInternet)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        // Should gracefully return empty, not crash
        XCTAssertEqual(candidates.count, 0)
    }

    func testHandlesAPIError() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            return MockGeminiResponses.httpResponse(url: request.url!, statusCode: 500)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        // Should gracefully return empty, not crash
        XCTAssertEqual(candidates.count, 0)
    }

    // MARK: - Message Filtering Tests

    func testFiltersNonUserAssistantMessages() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let extractor = await GeminiLearningExtractor(client: client)

        var requestReceived = false
        MockGeminiURLProtocol.requestHandler = { request in
            requestReceived = true
            let data = MockGeminiResponses.learnings([])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(provider: .claudeCode, sourceType: .cli, title: "Test")
        let messages = [
            Message(conversationId: conversation.id, role: .system, content: "System prompt", timestamp: Date()),
            Message(conversationId: conversation.id, role: .tool, content: "Tool output", timestamp: Date())
        ]

        _ = await extractor.extractLearnings(from: conversation, messages: messages)

        // Should not make request since no user/assistant messages
        XCTAssertFalse(requestReceived)
    }

    // MARK: - Type Normalization Tests

    func testHandlesLearningTypeNormalization() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)

        let config = GeminiLearningExtractor.Configuration(minConfidence: 0.5)
        let extractor = await GeminiLearningExtractor(client: client, configuration: config)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.learnings([
                (rule: "Correction type", type: "correction", confidence: 0.9),
                (rule: "Positive type", type: "positive", confidence: 0.9),
                (rule: "Implicit type", type: "implicit", confidence: 0.9)
            ])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let (conversation, messages) = makeTestConversation()
        let candidates = await extractor.extractLearnings(from: conversation, messages: messages)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].type, .correction)
        XCTAssertEqual(candidates[1].type, .positive)
        XCTAssertEqual(candidates[2].type, .implicit)
    }

    // MARK: - Helpers

    private func makeTestConversation() -> (Conversation, [Message]) {
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test conversation",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 3
        )

        let messages = [
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "Please use TypeScript for examples",
                timestamp: Date().addingTimeInterval(-120)
            ),
            Message(
                conversationId: conversation.id,
                role: .assistant,
                content: "Sure, I'll use TypeScript for all code examples.",
                timestamp: Date().addingTimeInterval(-60)
            ),
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "Perfect, that's exactly what I want",
                timestamp: Date()
            )
        ]

        return (conversation, messages)
    }
}
