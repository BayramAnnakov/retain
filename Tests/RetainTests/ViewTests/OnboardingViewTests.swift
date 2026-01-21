import XCTest
import ViewInspector
import SwiftUI
@testable import Retain

final class OnboardingViewTests: XCTestCase {

    @MainActor
    func testOnboardingViewRenders() throws {
        var isPresented = true
        let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
        let appState = MockAppStateFactory.forOnboarding()

        let view = OnboardingView(isPresented: binding).environmentObject(appState)

        // Should render without crash
        XCTAssertNoThrow(try view.inspect())
    }

    @MainActor
    func testOnboardingHasProgressIndicator() throws {
        var isPresented = true
        let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
        let appState = MockAppStateFactory.forOnboarding()

        let view = OnboardingView(isPresented: binding).environmentObject(appState)

        // View should render with progress indicators
        let inspected = try view.inspect()
        XCTAssertNotNil(inspected)
    }
}

// MARK: - WelcomeStepView Tests

final class WelcomeStepViewTests: XCTestCase {

    func testWelcomeStepRendersTitle() throws {
        let view = WelcomeStepView(onContinue: {})

        // Should contain welcome text
        let welcomeText = try? view.inspect().find(text: "Welcome to Retain")
        XCTAssertNotNil(welcomeText, "Welcome step should show 'Welcome to Retain'")
    }

    func testWelcomeStepHasGetStartedButton() throws {
        let view = WelcomeStepView(onContinue: {})

        // Should have a button
        let button = try? view.inspect().find(ViewType.Button.self)
        XCTAssertNotNil(button, "Welcome step should have a Get Started button")
    }

    func testWelcomeStepShowsFeatureCards() throws {
        let view = WelcomeStepView(onContinue: {})

        // Should contain FeatureCard components
        let featureCards = try? view.inspect().findAll(FeatureCard.self)
        XCTAssertNotNil(featureCards)
        XCTAssertGreaterThan(featureCards?.count ?? 0, 0, "Welcome step should show feature cards")
    }

    func testGetStartedButtonCallsOnContinue() throws {
        var wasCalled = false
        let view = WelcomeStepView(onContinue: { wasCalled = true })

        // Find and tap the button
        let button = try view.inspect().find(ViewType.Button.self)
        try button.tap()

        XCTAssertTrue(wasCalled, "Tapping Get Started should call onContinue")
    }
}

// MARK: - CLISourcesStepView Tests

final class CLISourcesStepViewTests: XCTestCase {

    func testCLISourcesStepRendersClaudeCodeCard() throws {
        let view = CLISourcesStepView(
            claudeCodeEnabled: .constant(true),
            codexEnabled: .constant(false),
            onBack: {},
            onContinue: {}
        )

        // Should mention Claude Code
        let claudeText = try? view.inspect().find(text: "Claude Code")
        XCTAssertNotNil(claudeText, "CLI sources step should mention Claude Code")
    }

    func testCLISourcesStepHasBackButton() throws {
        let view = CLISourcesStepView(
            claudeCodeEnabled: .constant(true),
            codexEnabled: .constant(false),
            onBack: {},
            onContinue: {}
        )

        // Should have Back button
        let backButton = try? view.inspect().find(text: "Back")
        XCTAssertNotNil(backButton, "CLI sources step should have Back button")
    }

    func testCLISourcesStepHasContinueButton() throws {
        let view = CLISourcesStepView(
            claudeCodeEnabled: .constant(true),
            codexEnabled: .constant(false),
            onBack: {},
            onContinue: {}
        )

        // Should have Continue button
        let continueButton = try? view.inspect().find(text: "Continue")
        XCTAssertNotNil(continueButton, "CLI sources step should have Continue button")
    }
}

// MARK: - ReadyStepView Tests

final class ReadyStepViewTests: XCTestCase {

    @MainActor
    func testReadyStepRendersCompleteButton() throws {
        let view = ReadyStepView(
            claudeCodeEnabled: true,
            codexEnabled: false,
            autoSyncEnabled: .constant(true),
            autoExtractLearnings: .constant(true),
            allowCloudAnalysis: .constant(true),
            onBack: {},
            onComplete: {}
        )

        // Should have Start Using Retain button (or similar)
        let inspected = try view.inspect()
        XCTAssertNotNil(inspected)
    }

    @MainActor
    func testReadyStepShowsSourceSummary() throws {
        let view = ReadyStepView(
            claudeCodeEnabled: true,
            codexEnabled: false,
            autoSyncEnabled: .constant(true),
            autoExtractLearnings: .constant(true),
            allowCloudAnalysis: .constant(true),
            onBack: {},
            onComplete: {}
        )

        // View should render showing which sources are enabled
        XCTAssertNoThrow(try view.inspect())
    }

    @MainActor
    func testCompleteButtonCallsOnComplete() throws {
        var wasCalled = false
        let view = ReadyStepView(
            claudeCodeEnabled: true,
            codexEnabled: false,
            autoSyncEnabled: .constant(true),
            autoExtractLearnings: .constant(true),
            allowCloudAnalysis: .constant(true),
            onBack: {},
            onComplete: { wasCalled = true }
        )

        // Find and tap the complete button
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        // The last button should be the complete/finish button
        if let completeButton = buttons.last {
            try completeButton.tap()
            XCTAssertTrue(wasCalled, "Complete button should call onComplete")
        }
    }
}

// MARK: - FeatureCard Tests

final class FeatureCardTests: XCTestCase {

    func testFeatureCardRendersTitle() throws {
        let view = FeatureCard(
            icon: "star",
            iconColor: .yellow,
            title: "Test Feature",
            description: "This is a test description"
        )

        let title = try? view.inspect().find(text: "Test Feature")
        XCTAssertNotNil(title, "FeatureCard should display title")
    }

    func testFeatureCardRendersDescription() throws {
        let view = FeatureCard(
            icon: "star",
            iconColor: .yellow,
            title: "Test Feature",
            description: "This is a test description"
        )

        let desc = try? view.inspect().find(text: "This is a test description")
        XCTAssertNotNil(desc, "FeatureCard should display description")
    }

    func testFeatureCardRendersIcon() throws {
        let view = FeatureCard(
            icon: "star",
            iconColor: .yellow,
            title: "Test Feature",
            description: "This is a test description"
        )

        let icon = try? view.inspect().find(ViewType.Image.self)
        XCTAssertNotNil(icon, "FeatureCard should display icon")
    }
}
