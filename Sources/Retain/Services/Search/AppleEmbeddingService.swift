import Foundation
import NaturalLanguage

/// Zero-dependency embedding service using Apple's built-in NLContextualEmbedding.
/// Available on macOS 14+ with no user setup required - the model is bundled with the OS.
///
/// Features:
/// - 512-dimensional BERT-based embeddings
/// - Supports 27 languages
/// - Works offline
/// - No external dependencies
///
/// This is the default provider for zero-effort semantic search.
actor AppleEmbeddingService: EmbeddingProvider {

    // MARK: - EmbeddingProvider

    let dimensions = 512  // BERT-based, fixed dimension
    let name = "Apple NaturalLanguage"

    // MARK: - Properties

    private var embedding: NLContextualEmbedding?
    private var isLoaded = false

    // MARK: - Init

    init() {
        // Initialize with English (most common for code conversations)
        if let contextualEmbedding = NLContextualEmbedding(language: .english) {
            self.embedding = contextualEmbedding
        }
    }

    // MARK: - EmbeddingProvider Implementation

    func isAvailable() async -> Bool {
        guard let embedding = embedding else { return false }

        // Check if model assets are downloaded
        if embedding.hasAvailableAssets {
            return true
        }

        // Try to request assets if not available
        do {
            try await requestAssetsIfNeeded()
            return embedding.hasAvailableAssets
        } catch {
            return false
        }
    }

    func embed(text: String) async throws -> [Float] {
        guard let embedding = embedding else {
            throw EmbeddingError.providerUnavailable
        }

        // Ensure assets are available
        try await requestAssetsIfNeeded()

        // Load the model if not already loaded
        if !isLoaded {
            try embedding.load()
            isLoaded = true
        }

        // Get embedding result (throws on failure in macOS 14+)
        let result: NLContextualEmbeddingResult
        do {
            result = try embedding.embeddingResult(for: text, language: .english)
        } catch {
            throw EmbeddingError.embeddingFailed("No embedding result for text: \(error.localizedDescription)")
        }

        // Aggregate token vectors into single sentence vector using mean pooling
        var aggregated = [Float](repeating: 0, count: dimensions)
        var tokenCount: Float = 0

        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == dimensions else { return true }
            for i in 0..<dimensions {
                aggregated[i] += Float(vector[i])  // Convert Double to Float
            }
            tokenCount += 1
            return true
        }

        // Average the vectors
        if tokenCount > 0 {
            aggregated = aggregated.map { $0 / tokenCount }
        }

        // Normalize to unit length for cosine similarity
        let magnitude = sqrt(aggregated.reduce(0) { $0 + $1 * $1 })
        if magnitude > 0 {
            aggregated = aggregated.map { $0 / magnitude }
        }

        return aggregated
    }

    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)

        for text in texts {
            let vector = try await embed(text: text)
            results.append(vector)
        }

        return results
    }

    // MARK: - Asset Management

    /// Request model assets to be downloaded if not already available
    private func requestAssetsIfNeeded() async throws {
        guard let embedding = embedding else {
            throw EmbeddingError.providerUnavailable
        }

        if embedding.hasAvailableAssets {
            return
        }

        // Request assets - this triggers download if needed
        // Note: This may take a moment on first use
        // In macOS 14+, requestAssets is an instance method on the embedding
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            embedding.requestAssets { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Verify assets are now available
        guard embedding.hasAvailableAssets else {
            throw EmbeddingError.assetDownloadFailed
        }
    }

    /// Unload the model to free memory
    func unload() {
        if isLoaded {
            embedding?.unload()
            isLoaded = false
        }
    }

    deinit {
        // Note: Can't call async unload() here, but Swift will clean up
    }
}
