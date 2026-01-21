import Foundation

/// Protocol for embedding providers (Apple NL, Ollama, etc.)
/// Enables zero-effort semantic search with Apple's built-in NLContextualEmbedding,
/// with optional Ollama for higher quality embeddings.
protocol EmbeddingProvider: Actor {
    /// Generate embedding vector for text
    func embed(text: String) async throws -> [Float]

    /// Batch embed multiple texts
    func embedBatch(texts: [String]) async throws -> [[Float]]

    /// Check if provider is available and ready
    func isAvailable() async -> Bool

    /// Vector dimensions produced by this provider
    var dimensions: Int { get }

    /// Provider name for display in UI
    var name: String { get }
}

/// Common errors for embedding providers
enum EmbeddingError: LocalizedError {
    case providerUnavailable
    case embeddingFailed(String)
    case assetDownloadFailed
    case dimensionMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "Embedding provider not available"
        case .embeddingFailed(let reason):
            return "Failed to generate embedding: \(reason)"
        case .assetDownloadFailed:
            return "Failed to download embedding model assets"
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimension mismatch: expected \(expected), got \(got)"
        }
    }
}
