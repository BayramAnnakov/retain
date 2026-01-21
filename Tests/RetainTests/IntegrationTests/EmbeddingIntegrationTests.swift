import XCTest
@testable import Retain

/// Integration tests requiring actual embedding services
final class EmbeddingIntegrationTests: XCTestCase {

    // MARK: - Apple Embedding Integration

    func testAppleEmbeddingEndToEnd() async throws {
        let service = AppleEmbeddingService()

        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        // Test real embedding generation
        let text = "This is a test conversation about Swift programming"
        let vector = try await service.embed(text: text)

        let dims = await service.dimensions
        XCTAssertEqual(vector.count, dims, "Should produce correct dimension vector")

        // Verify it's not all zeros
        let nonZero = vector.filter { $0 != 0 }.count
        XCTAssertGreaterThan(nonZero, dims / 2, "Most elements should be non-zero")

        print("Apple embedding test passed - \(dims) dimensions")
    }

    func testAppleEmbeddingSemanticQuality() async throws {
        let service = AppleEmbeddingService()

        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        // Test semantic similarity
        let programming1 = try await service.embed(text: "How to write a function in Python")
        let programming2 = try await service.embed(text: "Writing Python functions and methods")
        let cooking = try await service.embed(text: "Recipe for chocolate cake with frosting")

        let progSimilarity = programming1.cosineSimilarity(with: programming2)
        let crossSimilarity = programming1.cosineSimilarity(with: cooking)

        print("Programming similarity: \(progSimilarity)")
        print("Cross-domain similarity: \(crossSimilarity)")

        XCTAssertGreaterThan(progSimilarity, crossSimilarity,
                            "Related topics should have higher similarity than unrelated")
    }

    // MARK: - Ollama Integration

    func testOllamaEmbeddingEndToEnd() async throws {
        let service = OllamaService()

        guard await service.isAvailable() else {
            throw XCTSkip("Ollama not running - start with: ollama serve")
        }

        // Check if default model (embeddinggemma) is available
        let models = try await service.listModels()
        let modelName = OllamaService.defaultModel
        guard models.contains(where: { $0.name.contains(modelName) }) else {
            throw XCTSkip("\(modelName) not installed - run: ollama pull \(modelName)")
        }

        let text = "This is a test conversation about Swift programming"
        let vector = try await service.embed(text: text)

        let dims = await service.dimensions
        XCTAssertEqual(vector.count, dims, "Should produce correct dimension vector")

        print("Ollama embedding test passed - \(dims) dimensions with \(modelName)")
    }

    func testOllamaSemanticQuality() async throws {
        let service = OllamaService()

        guard await service.isAvailable() else {
            throw XCTSkip("Ollama not running")
        }

        let code1 = try await service.embed(text: "func sayHello() { print(\"Hello\") }")
        let code2 = try await service.embed(text: "function greet() { console.log('Hi') }")
        let prose = try await service.embed(text: "The weather is sunny and warm today")

        let codeSimilarity = code1.cosineSimilarity(with: code2)
        let crossSimilarity = code1.cosineSimilarity(with: prose)

        print("Code similarity: \(codeSimilarity)")
        print("Code vs prose: \(crossSimilarity)")

        XCTAssertGreaterThan(codeSimilarity, crossSimilarity,
                            "Similar code should have higher similarity than prose")
    }

    // MARK: - Provider Comparison

    func testProviderComparison() async throws {
        let appleService = AppleEmbeddingService()
        let ollamaService = OllamaService()

        let appleAvailable = await appleService.isAvailable()
        let ollamaAvailable = await ollamaService.isAvailable()

        print("Provider availability:")
        print("  Apple NL: \(appleAvailable)")
        print("  Ollama: \(ollamaAvailable)")

        guard appleAvailable || ollamaAvailable else {
            throw XCTSkip("No embedding provider available")
        }

        // Test with whichever is available
        let text = "Testing embedding providers"

        if appleAvailable {
            let appleVec = try await appleService.embed(text: text)
            print("Apple embedding: \(appleVec.count) dimensions")
        }

        if ollamaAvailable {
            let ollamaVec = try await ollamaService.embed(text: text)
            print("Ollama embedding: \(ollamaVec.count) dimensions")
        }
    }

    // MARK: - Performance Tests

    func testAppleEmbeddingPerformance() async throws {
        let service = AppleEmbeddingService()

        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let texts = (0..<50).map { "Test text number \($0) for performance testing with some additional content" }

        let start = Date()
        _ = try await service.embedBatch(texts: texts)
        let elapsed = Date().timeIntervalSince(start)

        let perText = elapsed / Double(texts.count)
        print("Apple: Embedded \(texts.count) texts in \(String(format: "%.2f", elapsed))s (\(String(format: "%.3f", perText * 1000))ms/text)")

        // Should complete in reasonable time (< 150ms per text on Apple Silicon)
        XCTAssertLessThan(perText, 0.15, "Embedding should be reasonably fast")
    }

    func testOllamaEmbeddingPerformance() async throws {
        let service = OllamaService()

        guard await service.isAvailable() else {
            throw XCTSkip("Ollama not running")
        }

        let texts = (0..<20).map { "Test text number \($0) for performance testing with some additional content" }

        let start = Date()
        _ = try await service.embedBatch(texts: texts)
        let elapsed = Date().timeIntervalSince(start)

        let perText = elapsed / Double(texts.count)
        print("Ollama: Embedded \(texts.count) texts in \(String(format: "%.2f", elapsed))s (\(String(format: "%.3f", perText * 1000))ms/text)")

        // Ollama might be slower, allow up to 500ms per text
        XCTAssertLessThan(perText, 0.5, "Ollama embedding should complete in reasonable time")
    }

    // MARK: - Semantic Search Integration

    @MainActor
    func testSemanticSearchWithRealProvider() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)
        let search = SemanticSearch(repository: repo)

        // Check if any provider is available
        let available = await search.checkAvailability()

        guard available else {
            throw XCTSkip("No embedding provider available")
        }

        print("Using provider: \(search.activeProviderName)")

        // Create test conversations
        let conv1 = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Swift async/await tutorial",
            messageCount: 1
        )
        let msg1 = Message(
            conversationId: conv1.id,
            role: .user,
            content: "How do I use async/await in Swift? I want to learn about concurrency."
        )
        try repo.insert(conv1, messages: [msg1])

        let conv2 = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Python web scraping",
            messageCount: 1
        )
        let msg2 = Message(
            conversationId: conv2.id,
            role: .user,
            content: "Help me scrape a website using BeautifulSoup and requests"
        )
        try repo.insert(conv2, messages: [msg2])

        // Index conversations
        try await search.indexConversation(conv1)
        try await search.indexConversation(conv2)

        // Search for Swift-related content
        let results = try await search.search(query: "Swift concurrency async await")

        print("Search results for 'Swift concurrency':")
        for result in results {
            print("  - \(result.conversation.title ?? "Untitled") (score: \(result.score), type: \(result.matchType))")
        }

        // Should find results
        XCTAssertGreaterThan(results.count, 0, "Should find results")
    }

    @MainActor
    func testHybridSearchCombinesFTSAndSemantic() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)
        let search = SemanticSearch(repository: repo)

        guard await search.checkAvailability() else {
            throw XCTSkip("No embedding provider available")
        }

        // Create conversation that will match both FTS and semantic
        let conv = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Machine learning neural networks",
            messageCount: 1
        )
        let msg = Message(
            conversationId: conv.id,
            role: .user,
            content: "How do I train a neural network for image classification using PyTorch?"
        )
        try repo.insert(conv, messages: [msg])

        // Index for semantic search
        try await search.indexConversation(conv)

        // Search should combine FTS (exact match) with semantic
        let results = try await search.search(query: "neural network training")

        print("Hybrid search results:")
        for result in results {
            print("  - \(result.conversation.title ?? "Untitled") (score: \(result.score), type: \(result.matchType))")
        }

        XCTAssertGreaterThan(results.count, 0, "Should find hybrid results")
    }
}
