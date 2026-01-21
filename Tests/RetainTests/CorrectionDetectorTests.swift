import XCTest
@testable import Retain

final class CorrectionDetectorTests: XCTestCase {
    var detector: CorrectionDetector!
    var testConversation: Conversation!

    override func setUp() {
        detector = CorrectionDetector()
        testConversation = Conversation(
            id: UUID(),
            provider: .claudeCode,
            sourceType: .cli,
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 0
        )
    }

    override func tearDown() {
        detector = nil
        testConversation = nil
    }

    // MARK: - Helper Methods

    private func makeMessages(_ contents: [(Role, String)]) -> [Message] {
        var messages: [Message] = []
        var timestamp = Date()

        for (role, content) in contents {
            messages.append(Message(
                id: UUID(),
                conversationId: testConversation.id,
                role: role,
                content: content,
                timestamp: timestamp
            ))
            timestamp = timestamp.addingTimeInterval(1)
        }

        return messages
    }

    // MARK: - Direct Correction Tests

    func testDetectNoActually() throws {
        let messages = makeMessages([
            (.user, "How do I create a variable?"),
            (.assistant, "You can use var to create a variable."),
            (.user, "No, actually use let instead of var.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.type, .correction)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.9)
    }

    func testDetectNoInstead() throws {
        let messages = makeMessages([
            (.user, "What library should I use?"),
            (.assistant, "I recommend using Library A."),
            (.user, "No, use Library B instead of Library A.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.type, .correction)
    }

    func testDetectThatsWrong() throws {
        let messages = makeMessages([
            (.user, "What's 2+2?"),
            (.assistant, "2+2 equals 5."),
            (.user, "That's wrong, use Int instead of String.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.type, .correction)
    }

    func testDetectYoureWrong() throws {
        let messages = makeMessages([
            (.user, "What color is the sky?"),
            (.assistant, "The sky is green."),
            (.user, "You're wrong, use blue instead of green.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.type, .correction)
    }

    func testDetectDoesntWork() throws {
        let messages = makeMessages([
            (.user, "How do I fix this?"),
            (.assistant, "Try using this approach: someMethod()"),
            (.user, "That doesn't work, use async/await instead of callbacks.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.type, .correction)
    }

    // MARK: - Preference Expression Tests

    func testDetectIPrefer() throws {
        let messages = makeMessages([
            (.user, "Show me an example"),
            (.assistant, "Here's an example with callbacks..."),
            (.user, "I prefer to use async/await instead of callbacks.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.type, .correction)
    }

    func testDetectPleaseUse() throws {
        let messages = makeMessages([
            (.user, "Write some code"),
            (.assistant, "Here's the code with UIKit..."),
            (.user, "Please use SwiftUI instead of UIKit.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
    }

    func testDetectAlwaysUse() throws {
        let messages = makeMessages([
            (.user, "Can you help me?"),
            (.assistant, "Sure!"),
            (.user, "Always use descriptive variable names in your code.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.9)
    }

    func testDetectNeverUse() throws {
        let messages = makeMessages([
            (.user, "Show me code"),
            (.assistant, "Here's the code..."),
            (.user, "Never use force unwrap in production code.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - Style Correction Tests

    func testDetectDontAddComments() throws {
        let messages = makeMessages([
            (.user, "Write a function"),
            (.assistant, "```swift\n// This function does X\nfunc foo() { }\n```"),
            (.user, "Don't add comments, I prefer clean code.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
    }

    func testDetectTooVerbose() throws {
        let messages = makeMessages([
            (.user, "Explain this concept"),
            (.assistant, "Let me explain in great detail... [long explanation]"),
            (.user, "That's too verbose, keep it concise.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
    }

    func testDetectKeepItSimple() throws {
        let messages = makeMessages([
            (.user, "Write some code"),
            (.assistant, "Here's a complex implementation..."),
            (.user, "Keep it simple, please.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - Technical Correction Tests

    func testDetectUseXInsteadOfY() throws {
        let messages = makeMessages([
            (.user, "How do I do this?"),
            (.assistant, "Use the old API for this."),
            (.user, "Use SwiftUI instead of UIKit.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.95)

        // Check extracted rule
        let rule = results.first?.extractedRule ?? ""
        XCTAssertTrue(rule.contains("SwiftUI") || rule.contains("instead"))
    }

    // MARK: - Positive Feedback Tests

    func testDetectPerfect() throws {
        detector.updatePositiveFeedbackEnabled(true)
        let messages = makeMessages([
            (.user, "Write a sorting function"),
            (.assistant, "Here's a quicksort implementation..."),
            (.user, "Perfect! Concise and clean.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        let positiveResults = results.filter { $0.type == .positive }
        XCTAssertFalse(positiveResults.isEmpty)
    }

    func testDetectExactlyWhatIWanted() throws {
        detector.updatePositiveFeedbackEnabled(true)
        let messages = makeMessages([
            (.user, "Format this data"),
            (.assistant, "Here's the formatted output..."),
            (.user, "That's exactly what I wanted, include examples like that.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        let positiveResults = results.filter { $0.type == .positive }
        XCTAssertFalse(positiveResults.isEmpty)
    }

    func testDetectYesThatsCorrect() throws {
        detector.updatePositiveFeedbackEnabled(true)
        let messages = makeMessages([
            (.user, "Is this right?"),
            (.assistant, "I think the answer is X."),
            (.user, "Yes, that's correct and concise!")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        let positiveResults = results.filter { $0.type == .positive }
        XCTAssertFalse(positiveResults.isEmpty)
    }

    // MARK: - Rule Extraction Tests

    func testExtractUseInsteadOfRule() throws {
        let messages = makeMessages([
            (.user, "Help me"),
            (.assistant, "Use approach A"),
            (.user, "Use SwiftUI instead of UIKit for this.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        let rule = results.first?.extractedRule ?? ""
        XCTAssertTrue(rule.contains("SwiftUI") || rule.contains("instead"))
    }

    func testExtractNeverRule() throws {
        let messages = makeMessages([
            (.user, "Write code"),
            (.assistant, "Here's code..."),
            (.user, "Never use implicitly unwrapped optionals.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        let rule = results.first?.extractedRule ?? ""
        XCTAssertTrue(rule.lowercased().contains("never"))
    }

    func testExtractAlwaysRule() throws {
        let messages = makeMessages([
            (.user, "Write code"),
            (.assistant, "Here's code..."),
            (.user, "Always add error handling.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        let rule = results.first?.extractedRule ?? ""
        XCTAssertTrue(rule.lowercased().contains("always"))
    }

    // MARK: - No Detection Tests

    func testNoDetectionForNormalConversation() throws {
        let messages = makeMessages([
            (.user, "What is Swift?"),
            (.assistant, "Swift is a programming language developed by Apple."),
            (.user, "Can you show me an example?"),
            (.assistant, "Here's a simple example: print(\"Hello\")")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        // Should have no or very few detections for normal conversation
        XCTAssertTrue(results.isEmpty || results.allSatisfy { $0.confidence < 0.7 })
    }

    func testNoDetectionForAssistantMessages() throws {
        let messages = makeMessages([
            (.user, "Help me"),
            (.assistant, "No, actually that's wrong. I prefer this approach. Always use X instead of Y.")
        ])

        // Assistant messages should not trigger detections
        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertTrue(results.isEmpty, "Should not detect patterns in assistant messages")
    }

    // MARK: - Context Extraction Tests

    func testContextIncludesPreviousAssistantMessage() throws {
        let messages = makeMessages([
            (.assistant, "I recommend using UIKit for this task."),
            (.user, "No, use SwiftUI instead.")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        XCTAssertFalse(results.isEmpty)
        let context = results.first?.context ?? ""
        XCTAssertTrue(context.contains("Assistant:") || context.contains("UIKit"))
    }

    // MARK: - Configuration Tests

    func testMinConfidenceThreshold() throws {
        let config = CorrectionDetector.Configuration(minConfidence: 0.95)
        let strictDetector = CorrectionDetector(configuration: config)

        let messages = makeMessages([
            (.user, "I prefer using X.")  // Lower confidence pattern
        ])

        let results = strictDetector.analyzeConversation(testConversation, messages: messages)

        // With high threshold, lower confidence detections should be filtered
        XCTAssertTrue(results.allSatisfy { $0.confidence >= 0.95 })
    }

    // MARK: - Multiple Detections Tests

    func testMultipleCorrectionsInConversation() throws {
        detector.updatePositiveFeedbackEnabled(true)
        let messages = makeMessages([
            (.user, "Write code"),
            (.assistant, "Here's code with UIKit..."),
            (.user, "No, use SwiftUI instead of UIKit."),
            (.assistant, "Here's SwiftUI code with var..."),
            (.user, "Always use let for constants."),
            (.assistant, "Updated code..."),
            (.user, "Perfect, concise answer!")
        ])

        let results = detector.analyzeConversation(testConversation, messages: messages)

        // Should detect multiple patterns
        XCTAssertGreaterThanOrEqual(results.count, 2)

        let corrections = results.filter { $0.type == .correction }
        let positives = results.filter { $0.type == .positive }

        XCTAssertFalse(corrections.isEmpty)
        XCTAssertFalse(positives.isEmpty)
    }
}
