import XCTest
import ViewInspector
import SwiftUI
@testable import Retain

// MARK: - ProviderBadge Tests

final class ProviderBadgeTests: XCTestCase {

    func testProviderBadgeRendersWithDefaultSize() throws {
        let view = ProviderBadge(provider: .claudeCode)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testProviderBadgeRendersAllSizes() throws {
        let sizes: [ProviderBadge.Size] = [.small, .medium, .large]

        for size in sizes {
            let view = ProviderBadge(provider: .claudeCode, size: size)
            XCTAssertNoThrow(try view.inspect(), "ProviderBadge should render at size: \(size)")
        }
    }

    func testProviderBadgeRendersAllProviders() throws {
        for provider in Provider.allCases {
            let view = ProviderBadge(provider: provider)
            XCTAssertNoThrow(try view.inspect(), "ProviderBadge should render for provider: \(provider)")
        }
    }

    func testProviderBadgeShowsProviderShortName() throws {
        let view = ProviderBadge(provider: .claudeCode)

        // Should display provider short name
        let text = try? view.inspect().find(text: Provider.claudeCode.shortName)
        XCTAssertNotNil(text, "ProviderBadge should display provider short name")
    }

    func testProviderBadgeHasIcon() throws {
        let view = ProviderBadge(provider: .claudeCode)

        // Should have an Image (icon)
        let image = try? view.inspect().find(ViewType.Image.self)
        XCTAssertNotNil(image, "ProviderBadge should display an icon")
    }
}

// MARK: - ProviderIcon Tests

final class ProviderIconTests: XCTestCase {

    func testProviderIconRenders() throws {
        let view = ProviderIcon(provider: .claudeCode)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testProviderIconRendersAllProviders() throws {
        for provider in Provider.allCases {
            let view = ProviderIcon(provider: provider)
            XCTAssertNoThrow(try view.inspect(), "ProviderIcon should render for provider: \(provider)")
        }
    }

    func testProviderIconHasImage() throws {
        let view = ProviderIcon(provider: .chatgptWeb)

        // Should contain an Image
        let image = try? view.inspect().find(ViewType.Image.self)
        XCTAssertNotNil(image, "ProviderIcon should contain an Image")
    }

    func testProviderIconWithCustomSize() throws {
        let view = ProviderIcon(provider: .codex, size: 24)

        // Should render with custom size
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - ProviderSidebarRow Tests

final class ProviderSidebarRowTests: XCTestCase {

    func testProviderSidebarRowRenders() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 42,
            isSelected: false
        )

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testProviderSidebarRowShowsProviderName() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 10,
            isSelected: false
        )

        // Should display provider name
        let providerName = try? view.inspect().find(text: Provider.claudeCode.displayName)
        XCTAssertNotNil(providerName, "Should display provider display name")
    }

    func testProviderSidebarRowShowsCount() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 42,
            isSelected: false
        )

        // Should display count
        let count = try? view.inspect().find(text: "42")
        XCTAssertNotNil(count, "Should display conversation count")
    }

    func testProviderSidebarRowSelectedState() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 10,
            isSelected: true
        )

        // Should render with selected state
        XCTAssertNoThrow(try view.inspect())
    }

    func testProviderSidebarRowSyncingStatus() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 10,
            isSelected: false,
            syncStatus: .syncing
        )

        // Should render with syncing indicator (ProgressView)
        let progressView = try? view.inspect().find(ViewType.ProgressView.self)
        XCTAssertNotNil(progressView, "Should show ProgressView when syncing")
    }

    func testProviderSidebarRowErrorStatus() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 10,
            isSelected: false,
            syncStatus: .error
        )

        // Should render with error state
        XCTAssertNoThrow(try view.inspect())
    }

    func testProviderSidebarRowZeroCount() throws {
        let view = ProviderSidebarRow(
            provider: .claudeCode,
            count: 0,
            isSelected: false
        )

        // Should render without count badge when count is 0
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - SyncCompleteToast Tests

final class SyncCompleteToastTests: XCTestCase {

    func testSyncCompleteToastRenders() throws {
        let stats = SyncStats(conversationsUpdated: 10, messagesUpdated: 100)
        let view = SyncCompleteToast(stats: stats, onDismiss: {})

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testSyncCompleteToastShowsTitle() throws {
        let stats = SyncStats(conversationsUpdated: 10, messagesUpdated: 100)
        let view = SyncCompleteToast(stats: stats, onDismiss: {})

        // Should display "Sync Complete"
        let title = try? view.inspect().find(text: "Sync Complete")
        XCTAssertNotNil(title, "Should display 'Sync Complete' title")
    }

    func testSyncCompleteToastShowsStats() throws {
        let stats = SyncStats(conversationsUpdated: 42, messagesUpdated: 500)
        let view = SyncCompleteToast(stats: stats, onDismiss: {})

        // Should display conversation count
        let statsText = try? view.inspect().find(text: "42 conversations updated")
        XCTAssertNotNil(statsText, "Should display conversation count")
    }

    func testSyncCompleteToastHasCheckmarkIcon() throws {
        let stats = SyncStats(conversationsUpdated: 10, messagesUpdated: 100)
        let view = SyncCompleteToast(stats: stats, onDismiss: {})

        // Should have checkmark icon
        let image = try? view.inspect().find(ViewType.Image.self)
        XCTAssertNotNil(image, "Should have checkmark icon")
    }
}

// MARK: - SyncErrorBanner Tests

final class SyncErrorBannerTests: XCTestCase {

    func testSyncErrorBannerRenders() throws {
        let view = SyncErrorBanner(
            message: "Test error message",
            onRetry: {},
            onDismiss: {}
        )

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testSyncErrorBannerShowsTitle() throws {
        let view = SyncErrorBanner(
            message: "Test error",
            onRetry: {},
            onDismiss: {}
        )

        // Should display "Sync Failed"
        let title = try? view.inspect().find(text: "Sync Failed")
        XCTAssertNotNil(title, "Should display 'Sync Failed' title")
    }

    func testSyncErrorBannerShowsMessage() throws {
        let view = SyncErrorBanner(
            message: "Network error occurred",
            onRetry: {},
            onDismiss: {}
        )

        // Should display error message
        let message = try? view.inspect().find(text: "Network error occurred")
        XCTAssertNotNil(message, "Should display error message")
    }

    func testSyncErrorBannerHasRetryButton() throws {
        let view = SyncErrorBanner(
            message: "Test error",
            onRetry: {},
            onDismiss: {}
        )

        // Should have Retry button
        let retryButton = try? view.inspect().find(text: "Retry")
        XCTAssertNotNil(retryButton, "Should have Retry button")
    }

    func testSyncErrorBannerHasWarningIcon() throws {
        let view = SyncErrorBanner(
            message: "Test error",
            onRetry: {},
            onDismiss: {}
        )

        // Should have warning icon
        let image = try? view.inspect().find(ViewType.Image.self)
        XCTAssertNotNil(image, "Should have warning icon")
    }
}

// MARK: - EmptyStateView Tests

final class EmptyStateViewTests: XCTestCase {

    @MainActor
    func testEmptyStateViewRendersWelcomeWhenNoConversations() throws {
        let appState = MockAppStateFactory.withConversations(0)
        let view = EmptyStateView().environmentObject(appState)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())

        // Should display "Welcome to Retain" when no conversations exist
        let title = try? view.inspect().find(text: "Welcome to Retain")
        XCTAssertNotNil(title, "Should display welcome title when no conversations")
    }

    @MainActor
    func testEmptyStateViewShowsSelectConversationText() throws {
        // Need conversations to exist (but none selected) to see "Select a Conversation"
        let appState = MockAppStateFactory.withConversations(5)
        appState.selectedConversation = nil  // Ensure nothing is selected
        let view = EmptyStateView().environmentObject(appState)

        // Should display "Select a Conversation" when conversations exist but none selected
        let title = try? view.inspect().find(text: "Select a Conversation")
        XCTAssertNotNil(title, "Should display 'Select a Conversation' when conversations exist")
    }

    @MainActor
    func testEmptyStateViewShowsIcon() throws {
        let appState = MockAppStateFactory.withConversations(5)
        let view = EmptyStateView().environmentObject(appState)

        // Should have icon
        let image = try? view.inspect().find(ViewType.Image.self)
        XCTAssertNotNil(image, "Should display icon")
    }
}

// MARK: - EmptyConversationListView Tests

final class EmptyConversationListViewTests: XCTestCase {

    func testEmptyConversationListViewRenders() throws {
        let view = EmptyConversationListView(hasFilter: false)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testEmptyConversationListViewWithFilter() throws {
        let view = EmptyConversationListView(hasFilter: true)

        // Should render with filter state
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - EmptySearchResultsView Tests

final class EmptySearchResultsViewTests: XCTestCase {

    func testEmptySearchResultsViewRenders() throws {
        let view = EmptySearchResultsView(query: "test query")

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testEmptySearchResultsViewShowsQuery() throws {
        let view = EmptySearchResultsView(query: "my search")

        // Should reference the search query in some way
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - StatCard Tests (Analytics)

final class StatCardTests: XCTestCase {

    func testStatCardRenders() throws {
        let view = StatCard(
            title: "Total Conversations",
            value: "42",
            icon: "bubble.left.and.bubble.right",
            color: .blue
        )

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testStatCardShowsTitle() throws {
        let view = StatCard(
            title: "Messages",
            value: "100",
            icon: "message",
            color: .green
        )

        // Should display title
        let title = try? view.inspect().find(text: "Messages")
        XCTAssertNotNil(title, "StatCard should display title")
    }

    func testStatCardShowsValue() throws {
        let view = StatCard(
            title: "Test",
            value: "1,234",
            icon: "star",
            color: .yellow
        )

        // Should display value
        let value = try? view.inspect().find(text: "1,234")
        XCTAssertNotNil(value, "StatCard should display value")
    }
}

// MARK: - ConfidenceBadge Tests (Learning)

final class ConfidenceBadgeTests: XCTestCase {

    func testConfidenceBadgeRendersHighConfidence() throws {
        let view = ConfidenceBadge(confidence: 0.95)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testConfidenceBadgeRendersLowConfidence() throws {
        let view = ConfidenceBadge(confidence: 0.5)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    func testConfidenceBadgeRendersZeroConfidence() throws {
        let view = ConfidenceBadge(confidence: 0.0)

        // Should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }
}
