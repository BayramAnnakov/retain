import XCTest
@testable import Retain

/// Unit tests for GeminiWorkflowSignatureExtractor
final class GeminiWorkflowSignatureExtractorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockGeminiURLProtocol.reset()
    }

    override func tearDown() {
        MockGeminiURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Priming Detection Tests

    func testDetectsPrimingFromPhrases() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        // Should detect priming without making API call
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Please familiarize yourself with the project"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "Review the docs and understand the codebase", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNotNil(signature)
        XCTAssertEqual(signature?.action, "prime")
        XCTAssertEqual(signature?.artifact, "context")
        XCTAssertTrue(signature?.domains.contains("setup") ?? false)
    }

    func testDetectsIsPrimingFlagFromGemini() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.workflow(
                action: "analyze",
                artifact: "context",
                domains: ["engineering"],
                isPriming: true,
                isAutomationCandidate: false
            )
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Understand the API structure"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "Read the API docs", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNotNil(signature)
        XCTAssertEqual(signature?.action, "prime")
        XCTAssertEqual(signature?.artifact, "context")
    }

    // MARK: - Automation Candidate Tests

    func testExtractsValidSignature() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.workflow(
                action: "summarize",
                artifact: "notes",
                domains: ["meeting", "sales"],
                isPriming: false,
                isAutomationCandidate: true
            )
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(
            provider: .chatgptWeb,
            sourceType: .web,
            title: "Summarize the sales meeting"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "Please summarize the meeting notes and key points", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNotNil(signature)
        XCTAssertEqual(signature?.action, "summarize")
        XCTAssertEqual(signature?.artifact, "notes")
        XCTAssertTrue(signature?.domains.contains("meeting") ?? false)
        XCTAssertTrue(signature?.domains.contains("sales") ?? false)
        XCTAssertTrue(signature?.signature.contains("summarize|notes") ?? false)
    }

    func testFiltersNonAutomationCandidates() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.workflow(
                action: "summarize",
                artifact: "notes",
                domains: ["meeting"],
                isPriming: false,
                isAutomationCandidate: false  // Not an automation candidate
            )
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(
            provider: .claudeWeb,
            sourceType: .web,
            title: "General conversation"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "Just chatting", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNil(signature)
    }

    func testFiltersNoneActionArtifact() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.workflow(
                action: "none",
                artifact: "none",
                domains: [],
                isPriming: false,
                isAutomationCandidate: true
            )
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Random chat"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "What's the weather?", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNil(signature)
    }

    // MARK: - Exclusion Tests

    func testExcludesLocalCommandOutput() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        var requestMade = false
        MockGeminiURLProtocol.requestHandler = { request in
            requestMade = true
            let data = MockGeminiResponses.workflow(action: "analyze", artifact: "notes", domains: [], isPriming: false, isAutomationCandidate: true)
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        // Title contains exclusion phrase
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "<local-command-stdout> error output"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "Fix this error", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNil(signature)
        XCTAssertFalse(requestMade, "Should not make API request for excluded content")
    }

    func testExcludesSessionContinuation() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        var requestMade = false
        MockGeminiURLProtocol.requestHandler = { request in
            requestMade = true
            let data = MockGeminiResponses.workflow(action: "analyze", artifact: "notes", domains: [], isPriming: false, isAutomationCandidate: true)
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Session continuation"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "This session is being continued from previous", timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNil(signature)
        XCTAssertFalse(requestMade)
    }

    // MARK: - Error Handling Tests

    func testHandlesEmptyConversation() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.workflow(
                action: "none",
                artifact: "none",
                domains: [],
                isPriming: false,
                isAutomationCandidate: false
            )
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: nil
        )
        let messages: [Message] = []

        // Should not crash
        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)
        XCTAssertNil(signature)
    }

    func testHandlesGeminiError() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            return MockGeminiResponses.httpResponse(url: request.url!, statusCode: 500)
        }

        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Summarize the document"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: "Please summarize", timestamp: Date())
        ]

        // Should gracefully return nil, not crash
        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)
        XCTAssertNil(signature)
    }

    // MARK: - Snippet Tests

    func testSnippetIsTrimmed() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let clientConfig = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: clientConfig, session: mockSession)
        let extractor = GeminiWorkflowSignatureExtractor(client: client)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.workflow(
                action: "summarize",
                artifact: "report",
                domains: ["content"],
                isPriming: false,
                isAutomationCandidate: true
            )
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let longMessage = "Summarize the report: " + String(repeating: "This is a very long message. ", count: 50)
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Summarize"
        )
        let messages = [
            Message(conversationId: conversation.id, role: .user, content: longMessage, timestamp: Date())
        ]

        let signature = await extractor.extractSignature(conversation: conversation, messages: messages)

        XCTAssertNotNil(signature)
        // Snippet should be trimmed to max 180 chars + "..." (183 total)
        XCTAssertLessThanOrEqual(signature?.snippet.count ?? 0, 183)
    }
}
