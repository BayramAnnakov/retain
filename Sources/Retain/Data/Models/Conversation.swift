import Foundation
import GRDB

/// A conversation from any AI platform
struct Conversation: Identifiable, Hashable {
    var id: UUID
    var provider: Provider
    var sourceType: SourceType
    var externalId: String?      // Provider's conversation ID (for dedup)
    var title: String?
    var summary: String?         // Auto-generated summary
    var previewText: String?     // First-line preview for list display
    var projectPath: String?     // For CLI tools, the project context
    var sourceFilePath: String?  // For CLI tools, the source JSONL path
    var createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    var embedding: Data?         // Vector embedding for semantic search
    var embeddingProvider: String?  // Which provider generated the embedding (e.g., "Apple NaturalLanguage", "Ollama")
    var rawPayload: Data?        // Raw provider payload for structured rendering

    init(
        id: UUID = UUID(),
        provider: Provider,
        sourceType: SourceType,
        externalId: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        previewText: String? = nil,
        projectPath: String? = nil,
        sourceFilePath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0,
        embedding: Data? = nil,
        embeddingProvider: String? = nil,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.provider = provider
        self.sourceType = sourceType
        self.externalId = externalId
        self.title = title
        self.summary = summary
        self.previewText = previewText
        self.projectPath = projectPath
        self.sourceFilePath = sourceFilePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.embedding = embedding
        self.embeddingProvider = embeddingProvider
        self.rawPayload = rawPayload
    }
}

// MARK: - GRDB Support

extension Conversation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversations"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let provider = Column(CodingKeys.provider)
        static let sourceType = Column(CodingKeys.sourceType)
        static let externalId = Column(CodingKeys.externalId)
        static let title = Column(CodingKeys.title)
        static let summary = Column(CodingKeys.summary)
        static let previewText = Column(CodingKeys.previewText)
        static let projectPath = Column(CodingKeys.projectPath)
        static let sourceFilePath = Column(CodingKeys.sourceFilePath)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let messageCount = Column(CodingKeys.messageCount)
        static let embedding = Column(CodingKeys.embedding)
        static let embeddingProvider = Column(CodingKeys.embeddingProvider)
        static let rawPayload = Column(CodingKeys.rawPayload)
    }

    // Association with messages
    static let messages = hasMany(Message.self)

    var messages: QueryInterfaceRequest<Message> {
        request(for: Conversation.messages)
    }
}

// MARK: - Full-Text Search Support

extension Conversation {
    /// Content to index for full-text search (title + summary)
    var searchableContent: String {
        [title, summary, previewText].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Equatable & Hashable (by ID only for SwiftUI List selection)

extension Conversation: Equatable {
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - UI Helpers

extension Conversation {
    /// Preview text for list display
    var preview: String? {
        if let previewText = previewText, !previewText.isEmpty {
            return previewText
        }
        if let summary = summary, !summary.isEmpty {
            return summary
        }
        return nil
    }

    /// Normalized display title for UI (handles empty/whitespace titles)
    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "Untitled Conversation"
    }
}
