import Foundation
import GRDB

/// Repository for conversation CRUD operations
final class ConversationRepository: @unchecked Sendable {
    private let database: AppDatabase

    struct UpsertResult {
        let id: UUID
        let didChange: Bool
    }

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Create

    /// Insert a new conversation with its messages
    func insert(_ conversation: Conversation, messages: [Message]) throws {
        try database.write { db in
            var conv = conversation
            try conv.insert(db)

            for var message in messages {
                message.conversationId = conv.id
                try message.insert(db)
            }

            // Update message count
            conv.messageCount = messages.count
            try conv.update(db)
        }
    }

    /// Insert or update a conversation (for sync)
    /// Uses smart merge strategy to preserve messages that have associated learnings
    func upsert(_ conversation: Conversation, messages: [Message]) throws -> UpsertResult {
        try database.write { db in
            // Check if conversation exists by external ID
            if let externalId = conversation.externalId,
               let existing = try Conversation
                .filter(Conversation.Columns.provider == conversation.provider.rawValue)
                .filter(Conversation.Columns.externalId == externalId)
                .fetchOne(db) {

                // === SMART MERGE STRATEGY ===
                // Don't delete messages wholesale - they may have learnings attached
                // Instead: update existing messages, insert new ones, leave orphans
                var didChange = false

                // 1. Build lookup of existing messages by externalId
                let existingMessages = try Message
                    .filter(Message.Columns.conversationId == existing.id)
                    .fetchAll(db)
                let existingByExternalId = Dictionary(
                    existingMessages.compactMap { m -> (String, Message)? in
                        guard let extId = m.externalId else { return nil }
                        return (extId, m)
                    },
                    uniquingKeysWith: { first, _ in first }
                )

                // 2. Process incoming messages - update or insert
                for var message in messages {
                    message.conversationId = existing.id

                    if let extId = message.externalId,
                       let existingMsg = existingByExternalId[extId] {
                        // Update existing message (preserves ID, so learnings FK stays valid)
                        message.id = existingMsg.id
                        if messageDiffers(from: existingMsg, incoming: message) {
                            try message.update(db)
                            didChange = true
                        }
                    } else {
                        // Insert new message
                        try message.insert(db)
                        didChange = true
                    }
                }

                // 3. Note: We intentionally do NOT delete old messages that are no longer
                // in the incoming set. They may have learnings attached via the FK.
                // The messageCount reflects the current sync source, not total messages.
                if conversation.provider == .chatgptWeb {
                    if try removeBlankSystemMessages(conversationId: existing.id, db: db) {
                        didChange = true
                    }
                }

                // 4. Update conversation (preserve embedding from existing)
                var updated = conversation
                updated.id = existing.id
                updated.embedding = conversation.embedding ?? existing.embedding
                updated.messageCount = messages.count
                let conversationChanged = existing.title != updated.title
                    || existing.summary != updated.summary
                    || existing.previewText != updated.previewText
                    || existing.projectPath != updated.projectPath
                    || existing.sourceFilePath != updated.sourceFilePath
                    || existing.updatedAt != updated.updatedAt
                    || existing.messageCount != updated.messageCount
                    || existing.rawPayload != updated.rawPayload

                if conversationChanged {
                    try updated.update(db)
                    didChange = true
                }

                return UpsertResult(id: existing.id, didChange: didChange)
            } else {
                // Insert new conversation and messages
                var conv = conversation
                try conv.insert(db)

                for var message in messages {
                    message.conversationId = conv.id
                    try message.insert(db)
                }

                conv.messageCount = messages.count
                try conv.update(db)
                if conversation.provider == .chatgptWeb {
                    _ = try removeBlankSystemMessages(conversationId: conv.id, db: db)
                }
                return UpsertResult(id: conv.id, didChange: true)
            }
        }
    }

    private func removeBlankSystemMessages(conversationId: UUID, db: Database) throws -> Bool {
        let deleted = try Message
            .filter(Message.Columns.conversationId == conversationId)
            .filter(Message.Columns.role == Role.system.rawValue)
            .filter(sql: "trim(content) = ''")
            .deleteAll(db)
        return deleted > 0
    }

    private func messageDiffers(from existing: Message, incoming: Message) -> Bool {
        existing.role != incoming.role
            || existing.content != incoming.content
            || existing.timestamp != incoming.timestamp
            || existing.model != incoming.model
            || existing.parentId != incoming.parentId
            || existing.externalId != incoming.externalId
            || existing.metadata != incoming.metadata
            || existing.rawPayload != incoming.rawPayload
    }

    // MARK: - Read

    /// Fetch all conversations ordered by update time (excludes soft-deleted)
    func fetchAll() throws -> [Conversation] {
        try database.read { db in
            try Conversation
                .filter(Conversation.Columns.deletedAt == nil)
                .order(Conversation.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch conversations by provider (excludes soft-deleted)
    func fetch(provider: Provider) throws -> [Conversation] {
        try database.read { db in
            try Conversation
                .filter(Conversation.Columns.provider == provider.rawValue)
                .filter(Conversation.Columns.deletedAt == nil)
                .order(Conversation.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single conversation by ID
    func fetch(id: UUID) throws -> Conversation? {
        try database.read { db in
            try Conversation.fetchOne(db, key: id)
        }
    }

    /// Fetch messages for a conversation
    func fetchMessages(conversationId: UUID) throws -> [Message] {
        try database.read { db in
            try Message
                .filter(Message.Columns.conversationId == conversationId)
                .order(Message.Columns.timestamp.asc)
                .fetchAll(db)
        }
    }

    /// Fetch recent conversations (for App Intents suggestions)
    func fetchRecent(limit: Int = 10) throws -> [Conversation] {
        try database.read { db in
            try Conversation
                .filter(Conversation.Columns.deletedAt == nil)
                .order(Conversation.Columns.updatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Search

    /// Full-text search across all messages
    /// NOTE: Uses aliased columns to avoid collision between messages.id and conversations.id
    func searchMessages(query: String, limit: Int = 50) throws -> [(Message, Conversation)] {
        try database.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
            // Explicitly select columns to avoid id/externalId collision between tables
            let sql = """
                SELECT
                    messages.id, messages.conversationId, messages.externalId, messages.parentId,
                    messages.role, messages.content, messages.timestamp, messages.model, messages.metadata, messages.rawPayload,
                    conversations.id AS conv_id, conversations.provider, conversations.sourceType,
                    conversations.externalId AS conv_externalId, conversations.title, conversations.summary, conversations.previewText,
                    conversations.projectPath, conversations.sourceFilePath, conversations.createdAt, conversations.updatedAt,
                    conversations.messageCount, conversations.embedding, conversations.embeddingProvider,
                    conversations.rawPayload AS conv_rawPayload
                FROM messages
                JOIN messages_fts ON messages_fts.rowid = messages.rowid
                JOIN conversations ON conversations.id = messages.conversationId
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern, limit])

            return rows.compactMap { row -> (Message, Conversation)? in
                guard let message = try? Message(row: row) else {
                    return nil
                }
                // Manually construct conversation from aliased columns
                // Note: UUID is stored as BLOB in SQLite, GRDB decodes it directly
                guard let convId: UUID = row["conv_id"],
                      let providerString: String = row["provider"],
                      let provider = Provider(rawValue: providerString),
                      let sourceTypeString: String = row["sourceType"],
                      let sourceType = SourceType(rawValue: sourceTypeString),
                      let createdAt: Date = row["createdAt"],
                      let updatedAt: Date = row["updatedAt"],
                      let messageCount: Int = row["messageCount"] else {
                    return nil
                }
                let conversation = Conversation(
                    id: convId,
                    provider: provider,
                    sourceType: sourceType,
                    externalId: row["conv_externalId"],
                    title: row["title"],
                    summary: row["summary"],
                    previewText: row["previewText"],
                    projectPath: row["projectPath"],
                    sourceFilePath: row["sourceFilePath"],
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    messageCount: messageCount,
                    embedding: row["embedding"],
                    embeddingProvider: row["embeddingProvider"],
                    rawPayload: row["conv_rawPayload"]
                )
                return (message, conversation)
            }
        }
    }

    /// Full-text search across conversation titles/summaries
    func searchConversations(query: String, limit: Int = 50) throws -> [Conversation] {
        try database.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
            let sql = """
                SELECT conversations.*
                FROM conversations
                JOIN conversations_fts ON conversations_fts.rowid = conversations.rowid
                WHERE conversations_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try Conversation.fetchAll(db, sql: sql, arguments: [pattern, limit])
        }
    }

    // MARK: - Delete

    /// Delete a conversation and its messages (cascade)
    /// Soft-delete a conversation (sets deletedAt timestamp)
    func delete(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE conversations SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// Restore a soft-deleted conversation
    func restore(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE conversations SET deletedAt = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Permanently delete a conversation (hard delete)
    func permanentlyDelete(id: UUID) throws {
        try database.write { db in
            try Conversation.deleteOne(db, key: id)
        }
    }

    /// Soft-delete all conversations from a provider
    func delete(provider: Provider) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE conversations SET deletedAt = ? WHERE provider = ?",
                arguments: [Date(), provider.rawValue]
            )
        }
    }

    /// Permanently delete all conversations from a provider (hard delete)
    func permanentlyDelete(provider: Provider) throws {
        try database.write { db in
            try Conversation
                .filter(Conversation.Columns.provider == provider.rawValue)
                .deleteAll(db)
        }
    }

    // MARK: - Update

    /// Update a conversation
    func update(_ conversation: Conversation) throws {
        try database.write { db in
            try conversation.update(db)
        }
    }

    // MARK: - Stats

    /// Get conversation count by provider
    func countByProvider() throws -> [Provider: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, COUNT(*) as count
                FROM conversations
                GROUP BY provider
                """)

            var result: [Provider: Int] = [:]
            for row in rows {
                if let providerString: String = row["provider"],
                   let provider = Provider(rawValue: providerString),
                   let count: Int = row["count"] {
                    result[provider] = count
                }
            }
            return result
        }
    }

    /// Get total message count
    func totalMessageCount() throws -> Int {
        try database.read { db in
            try Message.fetchCount(db)
        }
    }
}
