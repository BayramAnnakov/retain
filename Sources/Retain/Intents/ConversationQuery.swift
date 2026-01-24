import AppIntents
import Foundation

/// Query for fetching ConversationEntity objects
/// Used by App Intents framework for entity resolution
struct ConversationQuery: EntityQuery {
    /// Fetch entities by their identifiers
    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        let repository = ConversationRepository()
        return identifiers.compactMap { id in
            guard let conversation = try? repository.fetch(id: id) else {
                return nil
            }
            return ConversationEntity(from: conversation)
        }
    }

    /// Provide suggested entities (for type-ahead in Shortcuts)
    func suggestedEntities() async throws -> [ConversationEntity] {
        let repository = ConversationRepository()
        let conversations = try repository.fetchRecent(limit: 10)
        return conversations.map { ConversationEntity(from: $0) }
    }

    /// Default result for empty search
    func defaultResult() async -> ConversationEntity? {
        let repository = ConversationRepository()
        guard let conversation = try? repository.fetchRecent(limit: 1).first else {
            return nil
        }
        return ConversationEntity(from: conversation)
    }
}

/// String search query for conversations
struct ConversationStringQuery: EntityStringQuery {
    /// Fetch entities matching a search string
    func entities(matching string: String) async throws -> [ConversationEntity] {
        let repository = ConversationRepository()

        // Use full-text search
        let conversations = try repository.searchConversations(query: string, limit: 10)

        return conversations.map { conversation in
            ConversationEntity(from: conversation)
        }
    }

    /// Fetch entities by their identifiers
    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        let repository = ConversationRepository()
        return identifiers.compactMap { id in
            guard let conversation = try? repository.fetch(id: id) else {
                return nil
            }
            return ConversationEntity(from: conversation)
        }
    }

    /// Provide suggested entities
    func suggestedEntities() async throws -> [ConversationEntity] {
        let repository = ConversationRepository()
        let conversations = try repository.fetchRecent(limit: 10)
        return conversations.map { ConversationEntity(from: $0) }
    }
}
