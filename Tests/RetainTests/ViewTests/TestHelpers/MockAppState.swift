import Foundation
import SwiftUI
@testable import Retain

/// Factory for creating AppState instances with test data
/// Used for ViewInspector UI tests
@MainActor
enum MockAppStateFactory {

    // MARK: - State Factories

    /// Create AppState with sample conversations
    static func withConversations(_ count: Int = 5) -> AppState {
        let state = createBaseState()
        state.conversations = (0..<count).map { makeConversation(index: $0) }
        state.filteredConversations = state.conversations
        return state
    }

    /// Create AppState with active search results
    static func withSearchResults(query: String, resultCount: Int) -> AppState {
        let state = withConversations(10)
        state.searchQuery = query
        state.searchResults = (0..<resultCount).map { index in
            AppState.SearchResult(
                conversation: makeConversation(index: index),
                message: makeMessage(conversationId: UUID(), index: index),
                matchedText: "Match \(index) for '\(query)'"
            )
        }
        return state
    }

    /// Create AppState with selected conversation and messages
    static func withSelectedConversation(messageCount: Int = 5) -> AppState {
        let state = withConversations(5)
        let conversation = state.conversations.first!
        state.selectedConversation = conversation
        state.selectedMessages = (0..<messageCount).map { index in
            makeMessage(conversationId: conversation.id, index: index)
        }
        return state
    }

    /// Create AppState in syncing state
    static func syncing(progress: Double = 0.5) -> AppState {
        let state = withConversations()
        state.syncState.setStatus(.syncing)
        return state
    }

    /// Create AppState with error
    static func withError(_ message: String) -> AppState {
        let state = withConversations()
        state.errorMessage = message
        return state
    }

    /// Create AppState with provider stats
    static func withProviderStats() -> AppState {
        let state = withConversations(10)
        state.providerStats = [
            .claudeCode: 5,
            .codex: 2,
            .claudeWeb: 2,
            .chatgptWeb: 1
        ]
        return state
    }

    /// Create AppState for onboarding (not completed)
    static func forOnboarding() -> AppState {
        let state = createBaseState()
        state.hasCompletedOnboarding = false
        return state
    }

    // MARK: - Helpers

    /// Create a base AppState with minimal initialization
    /// Sets hasCompletedOnboarding to true to avoid auto-sync on init
    private static func createBaseState() -> AppState {
        // Create state - hasCompletedOnboarding defaults to false in init
        // but we can set it immediately after
        let state = AppState(syncService: SyncService())
        state.hasCompletedOnboarding = true
        return state
    }

    /// Create a sample conversation
    static func makeConversation(index: Int) -> Conversation {
        let providers = Provider.allCases
        return Conversation(
            id: UUID(),
            provider: providers[index % providers.count],
            sourceType: index % 2 == 0 ? .cli : .web,
            externalId: "ext-\(index)",
            title: "Test Conversation \(index)",
            summary: "Summary for conversation \(index). This is a test conversation used for UI testing.",
            projectPath: index % 2 == 0 ? "/path/to/project\(index)" : nil,
            createdAt: Date().addingTimeInterval(-Double(index) * 3600),
            updatedAt: Date().addingTimeInterval(-Double(index) * 1800),
            messageCount: (index + 1) * 10
        )
    }

    /// Create a sample message
    static func makeMessage(conversationId: UUID, index: Int) -> Message {
        Message(
            id: UUID(),
            conversationId: conversationId,
            role: index % 2 == 0 ? .user : .assistant,
            content: index % 2 == 0
                ? "This is a user message \(index). How do I implement feature X?"
                : "Here's how you can implement feature X:\n\n```swift\nfunc example() {\n    print(\"Hello\")\n}\n```\n\nThis approach uses the standard pattern.",
            timestamp: Date().addingTimeInterval(-Double(index) * 300)
        )
    }

    /// Create a sample learning
    static func makeLearning(conversationId: UUID, index: Int) -> Learning {
        Learning(
            id: UUID(),
            conversationId: conversationId,
            messageId: UUID(),
            type: index % 3 == 0 ? .correction : (index % 3 == 1 ? .positive : .implicit),
            pattern: "Pattern detected \(index)",
            extractedRule: "Always use \(index) pattern for better results",
            confidence: Float(0.7 + Double(index % 3) * 0.1),
            status: .pending,
            scope: index % 2 == 0 ? .global : .project
        )
    }
}

// MARK: - Convenience Extensions

extension AppState {
    /// Set up conversations quickly for tests
    @MainActor
    func setupTestConversations(_ count: Int) {
        conversations = (0..<count).map { MockAppStateFactory.makeConversation(index: $0) }
        filteredConversations = conversations
    }

    /// Set up messages for the selected conversation
    @MainActor
    func setupTestMessages(_ count: Int) {
        guard let conversation = selectedConversation else { return }
        selectedMessages = (0..<count).map {
            MockAppStateFactory.makeMessage(conversationId: conversation.id, index: $0)
        }
    }
}
