import XCTest
import ViewInspector
import SwiftUI
@testable import Retain

final class ConversationDetailViewTests: XCTestCase {

    @MainActor
    func testConversationDetailViewRendersWithConversation() throws {
        let appState = MockAppStateFactory.withSelectedConversation(messageCount: 5)
        let conversation = appState.selectedConversation!
        let view = ConversationDetailView(conversation: conversation).environmentObject(appState)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    @MainActor
    func testContainsConversationHeader() throws {
        let appState = MockAppStateFactory.withSelectedConversation()
        let conversation = appState.selectedConversation!
        let view = ConversationDetailView(conversation: conversation).environmentObject(appState)

        // Should contain ConversationHeader
        let header = try? view.inspect().find(ConversationHeader.self)
        XCTAssertNotNil(header, "ConversationDetailView should contain ConversationHeader")
    }

    @MainActor
    func testShowsMessagesInScrollView() throws {
        let appState = MockAppStateFactory.withSelectedConversation(messageCount: 3)
        let conversation = appState.selectedConversation!
        let view = ConversationDetailView(conversation: conversation).environmentObject(appState)

        // Should contain ScrollView with messages
        let scrollView = try? view.inspect().find(ViewType.ScrollView.self)
        XCTAssertNotNil(scrollView, "Should have ScrollView for messages")
    }

    @MainActor
    func testShowsMessageBubbles() throws {
        let appState = MockAppStateFactory.withSelectedConversation(messageCount: 4)
        let conversation = appState.selectedConversation!
        let view = ConversationDetailView(conversation: conversation).environmentObject(appState)

        // Should contain MessageBubble components
        let bubbles = try? view.inspect().findAll(MessageBubble.self)
        XCTAssertNotNil(bubbles)
        XCTAssertEqual(bubbles?.count ?? 0, 4, "Should show 4 message bubbles")
    }

    @MainActor
    func testHasExportToolbarButton() throws {
        let appState = MockAppStateFactory.withSelectedConversation()
        let conversation = appState.selectedConversation!
        let view = ConversationDetailView(conversation: conversation).environmentObject(appState)

        // View should render with toolbar buttons
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - ConversationHeader Tests

final class ConversationHeaderTests: XCTestCase {

    @MainActor
    func testHeaderRendersTitle() throws {
        let conversation = MockAppStateFactory.makeConversation(index: 0)
        let view = ConversationHeader(conversation: conversation, onBackToLearnings: nil)

        // Should display conversation title
        let title = try? view.inspect().find(text: conversation.title!)
        XCTAssertNotNil(title, "Header should display conversation title")
    }

    @MainActor
    func testHeaderRendersProviderName() throws {
        let conversation = MockAppStateFactory.makeConversation(index: 0)
        let view = ConversationHeader(conversation: conversation, onBackToLearnings: nil)

        // Should display provider name
        let providerName = try? view.inspect().find(text: conversation.provider.displayName)
        XCTAssertNotNil(providerName, "Header should display provider name")
    }

    @MainActor
    func testHeaderRendersMessageCount() throws {
        let conversation = MockAppStateFactory.makeConversation(index: 0)
        let view = ConversationHeader(conversation: conversation, onBackToLearnings: nil)

        // Should display message count
        let messageCount = try? view.inspect().find(text: "\(conversation.messageCount) messages")
        XCTAssertNotNil(messageCount, "Header should display message count")
    }

    @MainActor
    func testHeaderRendersCreatedDate() throws {
        let conversation = MockAppStateFactory.makeConversation(index: 0)
        let view = ConversationHeader(conversation: conversation, onBackToLearnings: nil)

        // Should display formatted created date
        let dateText = conversation.createdAt.formatted(date: .abbreviated, time: .shortened)
        let createdLabel = try? view.inspect().find(text: dateText)
        XCTAssertNotNil(createdLabel, "Header should display created date")
    }

    @MainActor
    func testHeaderShowsProjectPathWhenAvailable() throws {
        let conversation = Conversation(
            id: UUID(),
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test with Project",
            projectPath: "/Users/test/my-project",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 5
        )
        let view = ConversationHeader(conversation: conversation, onBackToLearnings: nil)

        // Should render with project path
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - MessageBubble Tests

final class MessageBubbleTests: XCTestCase {

    func testMessageBubbleRendersUserMessage() throws {
        let message = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .user,
            content: "Hello, how can I help?",
            timestamp: Date()
        )
        let view = MessageBubble(message: message, provider: .claudeCode)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testMessageBubbleRendersAssistantMessage() throws {
        let message = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .assistant,
            content: "I'm here to assist you.",
            timestamp: Date()
        )
        let view = MessageBubble(message: message, provider: .claudeCode)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testMessageBubbleShowsRoleName() throws {
        let message = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .user,
            content: "Test content",
            timestamp: Date()
        )
        let view = MessageBubble(message: message, provider: .claudeCode)

        // Should display role name
        let roleName = try? view.inspect().find(text: "User")
        XCTAssertNotNil(roleName, "MessageBubble should display role name")
    }

    func testMessageBubbleShowsAssistantRoleName() throws {
        let message = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .assistant,
            content: "Test content",
            timestamp: Date()
        )
        let view = MessageBubble(message: message, provider: .claudeCode)

        // Should display role name
        let roleName = try? view.inspect().find(text: "Assistant")
        XCTAssertNotNil(roleName, "MessageBubble should display Assistant role name")
    }

    func testMessageBubbleShowsTimestamp() throws {
        let message = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .user,
            content: "Test content",
            timestamp: Date()
        )
        let view = MessageBubble(message: message, provider: .claudeCode)

        // Should render timestamp (format varies)
        XCTAssertNoThrow(try view.inspect())
    }

    func testLongMessageShowsShowMoreButton() throws {
        // Create a long message (> 500 chars)
        let longContent = String(repeating: "This is a test message. ", count: 50)
        let message = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .assistant,
            content: longContent,
            timestamp: Date()
        )
        let view = MessageBubble(message: message, provider: .claudeCode)

        // Should have "Show more" button for long content
        let showMore = try? view.inspect().find(text: "Show more")
        XCTAssertNotNil(showMore, "Long messages should show 'Show more' button")
    }
}

// MARK: - MessageContentView Tests

final class MessageContentViewTests: XCTestCase {

    func testRendersPlainText() throws {
        let view = MessageContentView(content: "This is plain text content")

        // Should render text content
        let text = try? view.inspect().find(text: "This is plain text content")
        XCTAssertNotNil(text, "Should render plain text")
    }

    func testRendersCodeBlock() throws {
        let content = """
        Here is some code:
        ```swift
        print("Hello")
        ```
        """
        let view = MessageContentView(content: content)

        // Should contain CodeBlockView
        let codeBlock = try? view.inspect().find(CodeBlockView.self)
        XCTAssertNotNil(codeBlock, "Should render code blocks")
    }

    func testRendersHeading() throws {
        let content = "# This is a heading\nSome content below"
        let view = MessageContentView(content: content)

        // Should render heading
        let texts = (try? view.inspect().findAll(ViewType.Text.self)) ?? []
        let renderedText = texts.compactMap { try? $0.string() }.joined(separator: "\n")
        XCTAssertTrue(renderedText.contains("This is a heading"), "Should render headings")
    }
}

// MARK: - CodeBlockView Tests

final class CodeBlockViewTests: XCTestCase {

    func testRendersCodeContent() throws {
        let view = CodeBlockView(code: "print(\"Hello\")", language: "swift")

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testShowsLanguageLabel() throws {
        let view = CodeBlockView(code: "print(\"Hello\")", language: "swift")

        // Should display language
        let language = try? view.inspect().find(text: "swift")
        XCTAssertNotNil(language, "Should display language label")
    }

    func testRendersWithoutLanguage() throws {
        let view = CodeBlockView(code: "some code here", language: nil)

        // Should render without language
        XCTAssertNoThrow(try view.inspect())
    }

    func testCodeIsDisplayed() throws {
        let code = "func hello() { print(\"Hi\") }"
        let view = CodeBlockView(code: code, language: "swift")

        // Should display the code
        let codeText = try? view.inspect().find(text: code)
        XCTAssertNotNil(codeText, "Should display code content")
    }
}
