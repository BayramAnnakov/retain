import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Actor for indexing conversations in system Spotlight
/// Enables universal search across all synced AI conversations
actor SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private let searchableIndex = CSSearchableIndex.default()
    private let domainIdentifier = "com.retain.conversations"

    /// Maximum content description length (Spotlight recommendation)
    private let maxDescriptionLength = 300

    // MARK: - Indexing

    /// Index a single conversation with its messages
    func indexConversation(_ conversation: Conversation, messages: [Message]) async throws {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        let title = conversation.displayTitle

        // Both title and displayName are required for macOS 14+
        attributeSet.title = title
        attributeSet.displayName = title
        attributeSet.contentDescription = buildDescription(conversation: conversation, messages: messages)
        attributeSet.keywords = buildKeywords(conversation: conversation)
        attributeSet.contentCreationDate = conversation.createdAt
        attributeSet.contentModificationDate = conversation.updatedAt
        attributeSet.identifier = conversation.id.uuidString

        // Add provider-specific metadata
        attributeSet.subject = conversation.provider.displayName

        // Add project path if available (helps with context)
        if let projectPath = conversation.projectPath {
            attributeSet.path = projectPath
        }

        let item = CSSearchableItem(
            uniqueIdentifier: conversation.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )

        // Set expiration far in the future (we manage lifecycle ourselves)
        item.expirationDate = Date.distantFuture

        do {
            try await searchableIndex.indexSearchableItems([item])
            #if DEBUG
            print("[Spotlight] Indexed conversation: \(title)")
            #endif
        } catch {
            #if DEBUG
            print("[Spotlight] Failed to index conversation \(title): \(error)")
            #endif
            throw error
        }
    }

    /// Remove a conversation from the index
    func removeConversation(id: UUID) async throws {
        try await searchableIndex.deleteSearchableItems(withIdentifiers: [id.uuidString])
    }

    /// Remove multiple conversations from the index
    func removeConversations(ids: [UUID]) async throws {
        let identifiers = ids.map { $0.uuidString }
        try await searchableIndex.deleteSearchableItems(withIdentifiers: identifiers)
    }

    /// Reindex all conversations (batch operation)
    func reindexAll(conversations: [(Conversation, [Message])]) async throws {
        #if DEBUG
        print("[Spotlight] Starting reindex of \(conversations.count) conversations")
        #endif

        // Clear existing index first
        try await clearIndex()

        // Batch index all conversations
        var items: [CSSearchableItem] = []

        for (conversation, messages) in conversations {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
            let title = conversation.displayTitle

            // Both title and displayName are required for macOS 14+
            attributeSet.title = title
            attributeSet.displayName = title
            attributeSet.contentDescription = buildDescription(conversation: conversation, messages: messages)
            attributeSet.keywords = buildKeywords(conversation: conversation)
            attributeSet.contentCreationDate = conversation.createdAt
            attributeSet.contentModificationDate = conversation.updatedAt
            attributeSet.identifier = conversation.id.uuidString
            attributeSet.subject = conversation.provider.displayName

            if let projectPath = conversation.projectPath {
                attributeSet.path = projectPath
            }

            let item = CSSearchableItem(
                uniqueIdentifier: conversation.id.uuidString,
                domainIdentifier: domainIdentifier,
                attributeSet: attributeSet
            )
            item.expirationDate = Date.distantFuture

            items.append(item)
        }

        // Index in batches of 100 to avoid memory issues
        let batchSize = 100
        var indexedCount = 0
        for batch in stride(from: 0, to: items.count, by: batchSize) {
            let end = min(batch + batchSize, items.count)
            let batchItems = Array(items[batch..<end])
            do {
                try await searchableIndex.indexSearchableItems(batchItems)
                indexedCount += batchItems.count
            } catch {
                #if DEBUG
                print("[Spotlight] Failed to index batch: \(error)")
                #endif
                throw error
            }
        }

        #if DEBUG
        print("[Spotlight] Successfully indexed \(indexedCount) conversations")
        #endif
    }

    /// Clear all indexed items
    func clearIndex() async throws {
        try await searchableIndex.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
    }

    /// Get count of indexed items (for diagnostics)
    func indexedCount() async -> Int {
        // CoreSpotlight doesn't provide a direct count API
        // This is a placeholder - actual count would need to be tracked separately
        return 0
    }

    // MARK: - Private Helpers

    /// Build a search-friendly description from conversation and messages
    private func buildDescription(conversation: Conversation, messages: [Message]) -> String {
        var description = ""

        // Add preview text if available
        if let preview = conversation.previewText, !preview.isEmpty {
            description = preview
        } else if let summary = conversation.summary, !summary.isEmpty {
            description = summary
        } else {
            // Fall back to first user message content
            if let firstUserMessage = messages.first(where: { $0.role == .user }) {
                description = firstUserMessage.content
            }
        }

        // Truncate to recommended length
        if description.count > maxDescriptionLength {
            let endIndex = description.index(description.startIndex, offsetBy: maxDescriptionLength - 3)
            description = String(description[..<endIndex]) + "..."
        }

        return description
    }

    /// Build keywords for better search matching
    private func buildKeywords(conversation: Conversation) -> [String] {
        var keywords: [String] = []

        // Provider name
        keywords.append(conversation.provider.displayName)

        // Source type
        keywords.append(conversation.sourceType.rawValue)

        // Project name (last path component)
        if let projectPath = conversation.projectPath {
            if let projectName = projectPath.components(separatedBy: "/").last {
                keywords.append(projectName)
            }
        }

        // Add "AI", "conversation", "chat" for general discovery
        keywords.append(contentsOf: ["AI", "conversation", "chat", "Retain"])

        return keywords
    }
}
