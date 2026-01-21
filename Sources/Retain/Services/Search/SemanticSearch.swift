import Foundation
import GRDB

/// Hybrid search combining FTS5 full-text search with semantic vector search.
/// Uses Apple NLContextualEmbedding by default (zero setup), with optional Ollama
/// for higher quality embeddings when installed.
@MainActor
final class SemanticSearch: ObservableObject {
    // MARK: - Search Result

    struct SearchResult: Identifiable {
        let id = UUID()
        let conversation: Conversation
        let message: Message?
        let matchedText: String
        let score: Float
        let matchType: MatchType

        enum MatchType {
            case fullText
            case semantic
            case hybrid
        }
    }

    // MARK: - Configuration

    struct Configuration {
        var ftsWeight: Float = 0.5
        var semanticWeight: Float = 0.5
        var minSemanticScore: Float = 0.7
        var maxResults: Int = 50
        var enableSemanticSearch: Bool = true
        var preferOllama: Bool = false  // User preference for Ollama over Apple
    }

    // MARK: - Properties

    @Published private(set) var isIndexing = false
    @Published private(set) var indexProgress: Double = 0
    @Published private(set) var activeProviderName: String = "None"

    private let appleProvider: AppleEmbeddingService
    private let ollamaProvider: OllamaService
    private let repository: ConversationRepository
    private var config: Configuration

    // Cache for query embeddings (keyed by provider + query)
    private var queryEmbeddingCache: [String: [Float]] = [:]

    // MARK: - Init

    init(
        ollama: OllamaService = OllamaService(),
        repository: ConversationRepository = ConversationRepository(),
        configuration: Configuration = Configuration()
    ) {
        self.ollamaProvider = ollama
        self.appleProvider = AppleEmbeddingService()
        self.repository = repository
        self.config = configuration
    }

    // MARK: - Provider Selection

    /// Get the best available embedding provider.
    /// Priority: User preference (Ollama) > Apple NL > Ollama fallback
    private func getProvider() async -> (any EmbeddingProvider)? {
        // If user prefers Ollama and it's available, use it
        if config.preferOllama {
            let ollamaAvailable = await ollamaProvider.isAvailable()
            if ollamaAvailable {
                activeProviderName = ollamaProvider.name
                return ollamaProvider
            }
        }

        // Default to Apple (zero setup required)
        let appleAvailable = await appleProvider.isAvailable()
        if appleAvailable {
            activeProviderName = appleProvider.name
            return appleProvider
        }

        // Fall back to Ollama if Apple unavailable
        let ollamaAvailable = await ollamaProvider.isAvailable()
        if ollamaAvailable {
            activeProviderName = ollamaProvider.name
            return ollamaProvider
        }

        activeProviderName = "None"
        return nil
    }

    /// Update configuration (e.g., from Settings)
    func updateConfiguration(_ newConfig: Configuration) {
        self.config = newConfig
    }

    /// Check if semantic search is available
    func checkAvailability() async -> Bool {
        return await getProvider() != nil
    }

    // MARK: - Hybrid Search

    /// Perform hybrid search combining FTS5 and semantic search
    func search(query: String, messagesOnly: Bool = false) async throws -> [SearchResult] {
        var results: [SearchResult] = []
        var seenIds = Set<UUID>()

        // FTS5 search (on background thread)
        let ftsResults = try await performFTSSearch(query: query, messagesOnly: messagesOnly)
        for result in ftsResults {
            let id = result.message?.id ?? result.conversation.id
            if !seenIds.contains(id) {
                seenIds.insert(id)
                results.append(result)
            }
        }

        // Semantic search (if enabled and Ollama available)
        if config.enableSemanticSearch {
            let semanticResults = try await performSemanticSearch(query: query)
            for result in semanticResults {
                let id = result.message?.id ?? result.conversation.id
                if seenIds.contains(id) {
                    // Combine scores for hybrid result
                    if let index = results.firstIndex(where: { ($0.message?.id ?? $0.conversation.id) == id }) {
                        let ftsScore = results[index].score
                        let combinedScore = config.ftsWeight * ftsScore + config.semanticWeight * result.score
                        results[index] = SearchResult(
                            conversation: result.conversation,
                            message: result.message,
                            matchedText: result.matchedText,
                            score: combinedScore,
                            matchType: .hybrid
                        )
                    }
                } else {
                    seenIds.insert(id)
                    results.append(result)
                }
            }
        }

        // Sort by score descending
        results.sort { $0.score > $1.score }

        return Array(results.prefix(config.maxResults))
    }

    // MARK: - FTS5 Search

    private func performFTSSearch(query: String, messagesOnly: Bool) async throws -> [SearchResult] {
        // Run FTS search on background thread to avoid blocking MainActor
        let searchMessagesOnly = messagesOnly
        return try await Task.detached { [repository] in
            var results: [SearchResult] = []

            // Search messages
            let messageResults = try repository.searchMessages(query: query)
            for (message, conversation) in messageResults {
                results.append(SearchResult(
                    conversation: conversation,
                    message: message,
                    matchedText: message.preview(maxLength: 150),
                    score: 1.0, // FTS5 doesn't provide score directly, we normalize later
                    matchType: .fullText
                ))
            }

            // Search conversation titles (if not messages-only)
            if !searchMessagesOnly {
                let convResults = try repository.searchConversations(query: query)
                for conversation in convResults {
                    if !results.contains(where: { $0.conversation.id == conversation.id }) {
                        results.append(SearchResult(
                            conversation: conversation,
                            message: nil,
                            matchedText: conversation.title ?? "",
                            score: 0.8, // Slightly lower score for title matches
                            matchType: .fullText
                        ))
                    }
                }
            }

            return results
        }.value
    }

    // MARK: - Semantic Search

    private func performSemanticSearch(query: String) async throws -> [SearchResult] {
        // Get best available provider
        guard let provider = await getProvider() else {
            return []
        }

        let providerDimensions = await provider.dimensions
        let providerName = await provider.name
        let cacheKey = "\(providerName):\(query)"
        let minScore = config.minSemanticScore

        // Get query embedding (with caching)
        let queryEmbedding: [Float]
        if let cached = queryEmbeddingCache[cacheKey] {
            queryEmbedding = cached
        } else {
            queryEmbedding = try await provider.embed(text: query)
            queryEmbeddingCache[cacheKey] = queryEmbedding
        }

        // Get all conversations with embeddings (on background thread)
        let conversations = try await Task.detached { [repository] in
            try repository.fetchAll()
        }.value

        // Extract Sendable data for background compute: (id, embedding, provider, title)
        let embeddingData: [(UUID, [Float], String?, String?)] = conversations.compactMap { convo in
            guard let data = convo.embedding else { return nil }
            return (convo.id, [Float].fromData(data), convo.embeddingProvider, convo.title)
        }

        // Background compute using Task.detached with Sendable inputs
        // Includes cooperative cancellation check every 500 items
        let scoredIds: [(UUID, Float, String?)] = try await Task.detached {
            var results: [(UUID, Float, String?)] = []
            for (index, (id, embedding, provider, title)) in embeddingData.enumerated() {
                // Cooperative cancellation check every 500 items
                if index % 500 == 0 {
                    try Task.checkCancellation()
                }

                // Skip if provider doesn't match (different provider indexed this)
                guard provider == providerName else { continue }

                // Skip if dimensions don't match
                guard embedding.count == providerDimensions else { continue }

                let score = queryEmbedding.cosineSimilarity(with: embedding)
                if score >= minScore {
                    results.append((id, score, title))
                }
            }
            return results
        }.value

        // Build id → Conversation map ONCE for O(1) lookup
        let conversationMap = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        // Build SearchResult objects on MainActor
        return scoredIds.compactMap { (id, score, title) in
            guard let convo = conversationMap[id] else { return nil }
            return SearchResult(
                conversation: convo,
                message: nil,
                matchedText: title ?? "",
                score: score,
                matchType: .semantic
            )
        }
    }

    // MARK: - Indexing

    /// Index all conversations with embeddings
    func indexAllConversations() async throws {
        guard let provider = await getProvider() else {
            throw IndexingError.noProviderAvailable
        }

        let providerName = await provider.name
        let providerDimensions = await provider.dimensions

        isIndexing = true
        indexProgress = 0

        // Fetch conversations on background thread to avoid blocking MainActor
        let conversations = try await Task.detached { [repository] in
            try repository.fetchAll()
        }.value
        let total = conversations.count

        for (index, conversation) in conversations.enumerated() {
            // Skip if already has embedding with matching dimensions
            if let existingEmbedding = conversation.embedding {
                let dims = [Float].fromData(existingEmbedding).count
                if dims == providerDimensions { continue }
            }

            // Fetch messages on background thread
            let conversationId = conversation.id
            let messages = await Task.detached { [repository] in
                try? repository.fetchMessages(conversationId: conversationId)
            }.value

            // Generate embedding from title + first message content
            var textToEmbed = conversation.title ?? ""
            if let firstMessage = messages?.first {
                textToEmbed += " " + String(firstMessage.content.prefix(500))
            }

            guard !textToEmbed.isEmpty else { continue }

            do {
                let embedding = try await provider.embed(text: textToEmbed)
                var updatedConversation = conversation
                updatedConversation.embedding = embedding.toData()
                updatedConversation.embeddingProvider = providerName

                // Write update on background thread
                try await Task.detached { [repository] in
                    try repository.update(updatedConversation)
                }.value
            } catch {
                #if DEBUG
                print("Failed to embed conversation \(conversation.id): \(error)")
                #endif
            }

            indexProgress = Double(index + 1) / Double(total)

            // Small delay between embeddings
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        isIndexing = false
        indexProgress = 1.0
    }

    /// Index a single conversation
    func indexConversation(_ conversation: Conversation) async throws {
        guard let provider = await getProvider() else { return }

        let providerName = await provider.name
        let conversationId = conversation.id

        // Fetch messages on background thread
        let messages = await Task.detached { [repository] in
            try? repository.fetchMessages(conversationId: conversationId)
        }.value

        var textToEmbed = conversation.title ?? ""
        if let firstMessage = messages?.first {
            textToEmbed += " " + String(firstMessage.content.prefix(500))
        }

        guard !textToEmbed.isEmpty else { return }

        let embedding = try await provider.embed(text: textToEmbed)
        var updatedConversation = conversation
        updatedConversation.embedding = embedding.toData()
        updatedConversation.embeddingProvider = providerName

        // Write update on background thread
        try await Task.detached { [repository] in
            try repository.update(updatedConversation)
        }.value
    }

    /// Index specific conversations by IDs (incremental indexing after sync)
    func indexConversations(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        guard let provider = await getProvider() else {
            throw IndexingError.noProviderAvailable
        }

        let providerName = await provider.name
        let providerDimensions = await provider.dimensions

        // Fetch conversations on background thread
        let conversations = await Task.detached { [repository] in
            ids.compactMap { try? repository.fetch(id: $0) }
        }.value

        for conversation in conversations {
            // Skip if already has embedding from same provider with matching dimensions
            if let existingEmbedding = conversation.embedding,
               conversation.embeddingProvider == providerName {
                let dims = [Float].fromData(existingEmbedding).count
                if dims == providerDimensions { continue }
            }

            let conversationId = conversation.id

            // Fetch messages on background thread
            let messages = await Task.detached { [repository] in
                try? repository.fetchMessages(conversationId: conversationId)
            }.value

            var textToEmbed = conversation.title ?? ""
            if let firstMessage = messages?.first {
                textToEmbed += " " + String(firstMessage.content.prefix(500))
            }

            guard !textToEmbed.isEmpty else { continue }

            do {
                let embedding = try await provider.embed(text: textToEmbed)
                var updatedConversation = conversation
                updatedConversation.embedding = embedding.toData()
                updatedConversation.embeddingProvider = providerName

                // Write update on background thread
                try await Task.detached { [repository] in
                    try repository.update(updatedConversation)
                }.value
            } catch {
                #if DEBUG
                print("Failed to embed conversation \(conversation.id): \(error)")
                #endif
            }
        }
    }

    /// Clear all embeddings (useful when switching providers)
    func clearAllEmbeddings() throws {
        let conversations = try repository.fetchAll()
        for var conversation in conversations {
            conversation.embedding = nil
            conversation.embeddingProvider = nil
            try repository.update(conversation)
        }
        queryEmbeddingCache.removeAll()
    }

    // MARK: - Errors

    enum IndexingError: LocalizedError {
        case noProviderAvailable

        var errorDescription: String? {
            switch self {
            case .noProviderAvailable:
                return "No embedding provider available. Apple NL requires macOS 14+, Ollama requires installation."
            }
        }
    }
}
