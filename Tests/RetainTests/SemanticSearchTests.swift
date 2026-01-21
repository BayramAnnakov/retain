import XCTest
@testable import Retain

/// Unit tests for SemanticSearch
@MainActor
final class SemanticSearchTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = SemanticSearch.Configuration()

        XCTAssertEqual(config.ftsWeight, 0.5)
        XCTAssertEqual(config.semanticWeight, 0.5)
        XCTAssertEqual(config.minSemanticScore, 0.7)
        XCTAssertEqual(config.maxResults, 50)
        XCTAssertTrue(config.enableSemanticSearch)
        XCTAssertFalse(config.preferOllama)
    }

    func testCustomConfiguration() {
        var config = SemanticSearch.Configuration()
        config.ftsWeight = 0.7
        config.semanticWeight = 0.3
        config.preferOllama = true

        XCTAssertEqual(config.ftsWeight, 0.7)
        XCTAssertEqual(config.semanticWeight, 0.3)
        XCTAssertTrue(config.preferOllama)
    }

    // MARK: - Provider Selection Tests

    func testActiveProviderNameInitial() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)
        let search = SemanticSearch(repository: repo)

        // Initially should be "None" before any provider check
        XCTAssertEqual(search.activeProviderName, "None")
    }

    func testCheckAvailability() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)
        let search = SemanticSearch(repository: repo)

        // Just check that it doesn't crash
        _ = await search.checkAvailability()
    }

    // MARK: - Configuration Update Tests

    func testUpdateConfiguration() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)
        let search = SemanticSearch(repository: repo)

        var newConfig = SemanticSearch.Configuration()
        newConfig.preferOllama = true
        newConfig.maxResults = 100

        search.updateConfiguration(newConfig)

        // Configuration should be updated (internal, no public getter)
        // We just verify no crash
    }

    // MARK: - Search Result Tests

    func testSearchResultIdentifiable() {
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test"
        )

        let result1 = SemanticSearch.SearchResult(
            conversation: conversation,
            message: nil,
            matchedText: "test",
            score: 0.8,
            matchType: .fullText
        )

        let result2 = SemanticSearch.SearchResult(
            conversation: conversation,
            message: nil,
            matchedText: "test",
            score: 0.9,
            matchType: .semantic
        )

        // Each result should have unique ID
        XCTAssertNotEqual(result1.id, result2.id)
    }

    func testSearchResultMatchTypes() {
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test"
        )

        let ftsResult = SemanticSearch.SearchResult(
            conversation: conversation,
            message: nil,
            matchedText: "test",
            score: 1.0,
            matchType: .fullText
        )

        let semanticResult = SemanticSearch.SearchResult(
            conversation: conversation,
            message: nil,
            matchedText: "test",
            score: 0.8,
            matchType: .semantic
        )

        let hybridResult = SemanticSearch.SearchResult(
            conversation: conversation,
            message: nil,
            matchedText: "test",
            score: 0.9,
            matchType: .hybrid
        )

        XCTAssertEqual(ftsResult.matchType, .fullText)
        XCTAssertEqual(semanticResult.matchType, .semantic)
        XCTAssertEqual(hybridResult.matchType, .hybrid)
    }

    // MARK: - Indexing State Tests

    func testIsIndexingInitialState() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)
        let search = SemanticSearch(repository: repo)

        XCTAssertFalse(search.isIndexing)
        XCTAssertEqual(search.indexProgress, 0)
    }

    // MARK: - Search Tests (FTS only, no provider needed)

    func testSearchWithNoConversations() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)

        // Disable semantic search to only test FTS
        var config = SemanticSearch.Configuration()
        config.enableSemanticSearch = false
        let search = SemanticSearch(repository: repo, configuration: config)

        let results = try await search.search(query: "test")
        XCTAssertEqual(results.count, 0, "Should return no results for empty database")
    }

    func testSearchWithFTSOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)

        // Create test conversation with message
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Swift programming discussion",
            messageCount: 1
        )
        let message = Message(
            conversationId: conversation.id,
            role: .user,
            content: "How do I write Swift code?"
        )
        try repo.insert(conversation, messages: [message])

        // Disable semantic search to only test FTS
        var config = SemanticSearch.Configuration()
        config.enableSemanticSearch = false
        let search = SemanticSearch(repository: repo, configuration: config)

        let results = try await search.search(query: "Swift")

        XCTAssertGreaterThan(results.count, 0, "Should find FTS results")

        // Check that results are for full-text match
        for result in results {
            XCTAssertEqual(result.matchType, .fullText)
        }
    }

    func testSearchMessagesOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)

        // Create test conversation with title and message
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Python tutorial",
            messageCount: 1
        )
        let message = Message(
            conversationId: conversation.id,
            role: .user,
            content: "This is about Swift not Python"
        )
        try repo.insert(conversation, messages: [message])

        var config = SemanticSearch.Configuration()
        config.enableSemanticSearch = false
        let search = SemanticSearch(repository: repo, configuration: config)

        // Search messages only - should find Swift mention
        let messageResults = try await search.search(query: "Swift", messagesOnly: true)

        // Search all (including titles) - should also find Python in title
        let allResults = try await search.search(query: "Python", messagesOnly: false)

        XCTAssertGreaterThan(allResults.count, 0, "Should find Python in title")
    }

    // MARK: - Indexing Error Tests

    func testIndexingErrorDescription() {
        let error = SemanticSearch.IndexingError.noProviderAvailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("macOS 14") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("Ollama") ?? false)
    }

    // MARK: - Clear Embeddings Tests

    func testClearAllEmbeddings() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ConversationRepository(database: db)

        // Create conversation with embedding
        let conversation = Conversation(
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test",
            embedding: Data([0, 1, 2, 3]),
            embeddingProvider: "Test"
        )
        try repo.insert(conversation, messages: [])

        let search = SemanticSearch(repository: repo)
        try search.clearAllEmbeddings()

        // Verify embedding was cleared
        let fetched = try repo.fetch(id: conversation.id)
        XCTAssertNil(fetched?.embedding, "Embedding should be cleared")
        XCTAssertNil(fetched?.embeddingProvider, "Embedding provider should be cleared")
    }
}

// MARK: - Vector Math Tests (extension on Array<Float>)

final class VectorMathTests: XCTestCase {

    func testCosineSimilarityIdentical() {
        let vec1: [Float] = [1, 0, 0]
        let vec2: [Float] = [1, 0, 0]

        let similarity = vec1.cosineSimilarity(with: vec2)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001, "Identical vectors should have similarity 1")
    }

    func testCosineSimilarityOrthogonal() {
        let vec1: [Float] = [1, 0, 0]
        let vec2: [Float] = [0, 1, 0]

        let similarity = vec1.cosineSimilarity(with: vec2)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001, "Orthogonal vectors should have similarity 0")
    }

    func testCosineSimilarityOpposite() {
        let vec1: [Float] = [1, 0, 0]
        let vec2: [Float] = [-1, 0, 0]

        let similarity = vec1.cosineSimilarity(with: vec2)
        XCTAssertEqual(similarity, -1.0, accuracy: 0.001, "Opposite vectors should have similarity -1")
    }

    func testCosineSimilarityDifferentLengths() {
        let vec1: [Float] = [1, 0, 0]
        let vec2: [Float] = [1, 0]

        let similarity = vec1.cosineSimilarity(with: vec2)
        XCTAssertEqual(similarity, 0.0, "Different length vectors should return 0")
    }

    func testCosineSimilarityEmpty() {
        let vec1: [Float] = []
        let vec2: [Float] = []

        let similarity = vec1.cosineSimilarity(with: vec2)
        XCTAssertEqual(similarity, 0.0, "Empty vectors should return 0")
    }

    func testToDataAndBack() {
        let original: [Float] = [1.5, 2.5, 3.5, 4.5]
        let data = original.toData()
        let restored = [Float].fromData(data)

        XCTAssertEqual(restored.count, original.count)
        for i in 0..<original.count {
            XCTAssertEqual(restored[i], original[i], accuracy: 0.0001)
        }
    }
}
