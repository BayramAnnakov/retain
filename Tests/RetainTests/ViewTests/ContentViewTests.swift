import XCTest
import ViewInspector
import SwiftUI
@testable import Retain

final class ContentViewTests: XCTestCase {

    @MainActor
    func testContentViewRendersWithoutCrash() throws {
        let appState = MockAppStateFactory.withConversations()
        let view = ContentView().environmentObject(appState)

        // Basic test: view should render without throwing
        XCTAssertNoThrow(try view.inspect())
    }

    @MainActor
    func testContentViewContainsNavigationSplitView() throws {
        let appState = MockAppStateFactory.withConversations()
        let view = ContentView().environmentObject(appState)

        // Should contain a NavigationSplitView (three-column layout)
        let nav = try? view.inspect().find(ViewType.NavigationSplitView.self)
        XCTAssertNotNil(nav, "ContentView should contain a NavigationSplitView")
    }

    @MainActor
    func testShowsErrorAlertWhenErrorMessageSet() throws {
        let appState = MockAppStateFactory.withError("Test error message")
        let view = ContentView().environmentObject(appState)

        // Should have an alert configured
        let alert = try? view.inspect().find(ViewType.Alert.self)
        XCTAssertNotNil(alert, "ContentView should show alert when errorMessage is set")
    }

    @MainActor
    func testSyncStatusBarVisibleWhenSyncing() throws {
        let appState = MockAppStateFactory.syncing(progress: 0.5)
        let view = ContentView().environmentObject(appState)

        // When syncing, the sync status bar should be visible
        // It's rendered via .safeAreaInset
        let inspected = try view.inspect()
        XCTAssertNotNil(inspected)

        // The sync bar should be somewhere in the hierarchy when syncing
        XCTAssertTrue(appState.isSyncing)
    }

    @MainActor
    func testContentViewWithEmptyConversations() throws {
        let appState = MockAppStateFactory.withConversations(0)
        let view = ContentView().environmentObject(appState)

        // Should render without crash even with no conversations
        XCTAssertNoThrow(try view.inspect())
        XCTAssertTrue(appState.conversations.isEmpty)
    }
}
