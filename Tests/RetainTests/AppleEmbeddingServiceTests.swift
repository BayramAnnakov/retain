import XCTest
@testable import Retain

/// Unit tests for AppleEmbeddingService
final class AppleEmbeddingServiceTests: XCTestCase {

    var service: AppleEmbeddingService!

    override func setUp() async throws {
        service = AppleEmbeddingService()
    }

    override func tearDown() async throws {
        service = nil
    }

    // MARK: - Basic Properties Tests

    func testDimensions() async {
        let dims = await service.dimensions
        XCTAssertEqual(dims, 512, "Apple embedding should have 512 dimensions (BERT-based)")
    }

    func testName() async {
        let name = await service.name
        XCTAssertEqual(name, "Apple NaturalLanguage")
    }

    // MARK: - Availability Tests

    func testIsAvailable() async {
        // On macOS 14+, should be available (may need asset download)
        let available = await service.isAvailable()
        // Don't fail if assets not downloaded, just log
        print("Apple embedding available: \(available)")
        // This is a soft test - we don't fail if unavailable
        // as it depends on system state
    }

    // MARK: - Embedding Generation Tests

    func testEmbedSimpleText() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let vector = try await service.embed(text: "Hello world")

        XCTAssertEqual(vector.count, 512, "Should return 512-dimensional vector")

        // Vector should not be all zeros
        let nonZero = vector.filter { $0 != 0 }.count
        XCTAssertGreaterThan(nonZero, 400, "Most elements should be non-zero")
    }

    func testEmbedLongText() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let longText = String(repeating: "This is a test sentence. ", count: 100)
        let vector = try await service.embed(text: longText)

        XCTAssertEqual(vector.count, 512, "Should handle long text")
    }

    func testEmbedEmptyText() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        // Empty text might return zero vector or throw - both acceptable
        do {
            let vector = try await service.embed(text: "")
            // If it succeeds, should still be 512 dims
            XCTAssertEqual(vector.count, 512)
        } catch {
            // Throwing on empty text is acceptable
            XCTAssertTrue(error is EmbeddingError)
        }
    }

    func testEmbedSpecialCharacters() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let text = "Hello! How are you? 你好 🎉 @#$%"
        let vector = try await service.embed(text: text)

        XCTAssertEqual(vector.count, 512, "Should handle special characters")
    }

    // MARK: - Embedding Quality Tests

    func testSimilarTextsSimilarEmbeddings() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let vec1 = try await service.embed(text: "The cat sat on the mat")
        let vec2 = try await service.embed(text: "A cat is sitting on a mat")
        let vec3 = try await service.embed(text: "Quantum physics equations about wave functions")

        let sim12 = cosineSimilarity(vec1, vec2)
        let sim13 = cosineSimilarity(vec1, vec3)

        print("Similarity (similar): \(sim12)")
        print("Similarity (different): \(sim13)")

        // The key assertion: similar texts should have higher similarity than dissimilar ones
        XCTAssertGreaterThan(sim12, sim13, "Similar texts should have higher similarity than dissimilar texts")
        XCTAssertGreaterThan(sim12, 0.5, "Similar texts should have >0.5 similarity")
        // Note: General embeddings can have moderate similarity even for dissimilar texts
        // The important thing is that similar texts rank higher
    }

    func testIdenticalTextsIdenticalEmbeddings() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let text = "This is a test"
        let vec1 = try await service.embed(text: text)
        let vec2 = try await service.embed(text: text)

        let similarity = cosineSimilarity(vec1, vec2)
        XCTAssertGreaterThan(similarity, 0.99, "Identical texts should produce identical embeddings")
    }

    // MARK: - Batch Embedding Tests

    func testBatchEmbed() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let texts = ["Hello", "World", "Test", "Batch", "Embedding"]
        let vectors = try await service.embedBatch(texts: texts)

        XCTAssertEqual(vectors.count, 5, "Should return vector for each input")

        for (i, vec) in vectors.enumerated() {
            XCTAssertEqual(vec.count, 512, "Vector \(i) should be 512-dimensional")
        }
    }

    func testBatchEmbedEmpty() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let vectors = try await service.embedBatch(texts: [])
        XCTAssertEqual(vectors.count, 0, "Empty input should return empty output")
    }

    // MARK: - Normalization Tests

    func testEmbeddingsAreNormalized() async throws {
        guard await service.isAvailable() else {
            throw XCTSkip("Apple embedding assets not available")
        }

        let vector = try await service.embed(text: "Test normalization")
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })

        // Should be approximately unit length (normalized)
        XCTAssertEqual(magnitude, 1.0, accuracy: 0.01, "Embeddings should be normalized to unit length")
    }

    // MARK: - Helper Methods

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let magA = sqrt(a.reduce(0) { $0 + $1 * $1 })
        let magB = sqrt(b.reduce(0) { $0 + $1 * $1 })

        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
    }
}
