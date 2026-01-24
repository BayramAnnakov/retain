import AppIntents
import Foundation

/// App Intents entity representing a conversation
/// Makes conversations searchable in Spotlight and accessible via Shortcuts
struct ConversationEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")

    /// Default query for fetching entities
    static var defaultQuery = ConversationQuery()

    /// Unique identifier
    var id: UUID

    /// Conversation title
    @Property(title: "Title")
    var title: String

    /// Provider name (Claude Code, ChatGPT, etc.)
    @Property(title: "Provider")
    var provider: String

    /// Last update date
    @Property(title: "Updated")
    var updatedAt: Date

    /// Number of messages
    @Property(title: "Messages")
    var messageCount: Int

    /// Project path (for CLI providers)
    @Property(title: "Project")
    var projectPath: String?

    /// Display representation for Shortcuts and Spotlight
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(provider) - \(messageCount) messages"
        )
    }

    /// Initialize from a Conversation model
    init(from conversation: Conversation) {
        self.id = conversation.id
        self.title = conversation.displayTitle
        self.provider = conversation.provider.displayName
        self.updatedAt = conversation.updatedAt
        self.messageCount = conversation.messageCount
        self.projectPath = conversation.projectPath
    }

    /// Initialize directly (for testing or manual creation)
    init(id: UUID, title: String, provider: String, updatedAt: Date, messageCount: Int, projectPath: String? = nil) {
        self.id = id
        self.title = title
        self.provider = provider
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.projectPath = projectPath
    }
}
