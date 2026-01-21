import Foundation
import GRDB

/// A single message within a conversation
struct Message: Identifiable, Equatable {
    var id: UUID
    var conversationId: UUID
    var externalId: String?      // Provider's message ID
    var parentId: UUID?          // For threaded conversations
    var role: Role
    var content: String
    var timestamp: Date
    var model: String?           // Model used (e.g., "claude-3-opus", "gpt-4")
    var metadata: Data?          // Provider-specific JSON blob
    var rawPayload: Data?        // Raw provider payload for structured rendering

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        externalId: String? = nil,
        parentId: UUID? = nil,
        role: Role,
        content: String,
        timestamp: Date = Date(),
        model: String? = nil,
        metadata: Data? = nil,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.externalId = externalId
        self.parentId = parentId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
        self.metadata = metadata
        self.rawPayload = rawPayload
    }
}

// MARK: - GRDB Support

extension Message: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let conversationId = Column(CodingKeys.conversationId)
        static let externalId = Column(CodingKeys.externalId)
        static let parentId = Column(CodingKeys.parentId)
        static let role = Column(CodingKeys.role)
        static let content = Column(CodingKeys.content)
        static let timestamp = Column(CodingKeys.timestamp)
        static let model = Column(CodingKeys.model)
        static let metadata = Column(CodingKeys.metadata)
        static let rawPayload = Column(CodingKeys.rawPayload)
    }

    // Association with conversation
    static let conversation = belongsTo(Conversation.self)

    var conversation: QueryInterfaceRequest<Conversation> {
        request(for: Message.conversation)
    }
}

// MARK: - Full-Text Search Support

extension Message {
    /// Content to index for full-text search
    var searchableContent: String {
        content
    }
}

// MARK: - Convenience

extension Message {
    /// Check if this is a user message
    var isUserMessage: Bool {
        role == .user
    }

    /// Check if this is an assistant response
    var isAssistantMessage: Bool {
        role == .assistant
    }

    /// Truncated content for preview
    func preview(maxLength: Int = 100) -> String {
        if content.count <= maxLength {
            return content
        }
        let endIndex = content.index(content.startIndex, offsetBy: maxLength)
        return String(content[..<endIndex]) + "..."
    }
}
