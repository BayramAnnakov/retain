import AppIntents
import Foundation

// MARK: - Search Conversations Intent

/// Intent to search conversations by query
struct SearchConversationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Conversations"
    static var description = IntentDescription("Search your AI conversations in Retain")

    @Parameter(title: "Query", description: "The search term to look for")
    var query: String

    @Parameter(title: "Limit", description: "Maximum number of results", default: 5)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> {
        let repository = ConversationRepository()
        let conversations = try repository.searchConversations(query: query, limit: limit)
        let entities = conversations.map { ConversationEntity(from: $0) }
        return .result(value: entities)
    }
}

// MARK: - Sync Conversations Intent

/// Intent to trigger a sync of all conversations
struct SyncConversationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Conversations"
    static var description = IntentDescription("Sync all AI conversation sources in Retain")

    static var parameterSummary: some ParameterSummary {
        Summary("Sync all conversations")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Trigger sync via AppState
        await MainActor.run {
            AppState.shared?.triggerSync()
        }
        return .result(dialog: "Syncing conversations...")
    }
}

// MARK: - Open Conversation Intent

/// Intent to open a specific conversation
struct OpenConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Conversation"
    static var description = IntentDescription("Open a conversation in Retain")
    static var openAppWhenRun = true

    @Parameter(title: "Conversation", description: "The conversation to open")
    var conversation: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$conversation)")
    }

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run {
            AppState.shared?.navigateToConversation(id: conversation.id)
        }
        return .result()
    }
}

// MARK: - Open Learnings Intent

/// Intent to open the learnings view
struct OpenLearningsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Learnings"
    static var description = IntentDescription("Open the learnings review in Retain")
    static var openAppWhenRun = true

    static var parameterSummary: some ParameterSummary {
        Summary("Open learnings review")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AppState.shared?.navigateToLearnings()
        }

        let count = await MainActor.run {
            AppState.shared?.pendingLearningsCount ?? 0
        }

        if count > 0 {
            return .result(dialog: "You have \(count) pending learnings to review")
        } else {
            return .result(dialog: "No pending learnings")
        }
    }
}

// MARK: - Get Recent Conversations Intent

/// Intent to get a list of recent conversations
struct GetRecentConversationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Recent Conversations"
    static var description = IntentDescription("Get a list of recent AI conversations")

    @Parameter(title: "Count", description: "Number of conversations to return", default: 5)
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$count) recent conversations")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> {
        let repository = ConversationRepository()
        let conversations = try repository.fetchRecent(limit: count)
        let entities = conversations.map { ConversationEntity(from: $0) }
        return .result(value: entities)
    }
}

// MARK: - Get Pending Learnings Count Intent

/// Intent to get the count of pending learnings
struct GetPendingLearningsCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Pending Learnings Count"
    static var description = IntentDescription("Get the number of pending learnings to review")

    static var parameterSummary: some ParameterSummary {
        Summary("Get pending learnings count")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = await MainActor.run {
            AppState.shared?.pendingLearningsCount ?? 0
        }

        let dialog: IntentDialog = count > 0
            ? "You have \(count) pending learnings to review"
            : "No pending learnings"

        return .result(value: count, dialog: dialog)
    }
}
