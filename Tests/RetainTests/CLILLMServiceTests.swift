import XCTest
@testable import Retain

final class CLILLMServiceTests: XCTestCase {

    // MARK: - ConversationData Tests

    func testConversationDataTruncatedLimitsMessageCount() {
        let messages = (0..<20).map { i in
            MessageData(id: nil, role: "user", content: "Message \(i) with some content here")
        }
        let convo = ConversationData(id: "test", title: "Test", messages: messages)

        // maxMessages=6 -> half=3, so we get first 3 + last 3 = 6 messages
        let truncated = convo.truncated(maxCharsPerMessage: 100, maxMessages: 6)

        XCTAssertEqual(truncated.messages.count, 6, "Should limit to maxMessages (first half + last half)")
        XCTAssertTrue(truncated.wasTruncated, "Should be marked as truncated")
    }

    func testConversationDataTruncatedKeepsFirstAndLast() {
        let messages = (0..<10).map { i in
            MessageData(id: nil, role: "user", content: "Message \(i)")
        }
        let convo = ConversationData(id: "test", title: "Test", messages: messages)

        let truncated = convo.truncated(maxCharsPerMessage: 100, maxMessages: 4)

        // Should have first 2 and last 2 messages
        XCTAssertEqual(truncated.messages.count, 4)
        XCTAssertEqual(truncated.messages[0].content, "Message 0")
        XCTAssertEqual(truncated.messages[1].content, "Message 1")
        XCTAssertEqual(truncated.messages[2].content, "Message 8")
        XCTAssertEqual(truncated.messages[3].content, "Message 9")
    }

    func testConversationDataTruncatedLimitsCharactersPerMessage() {
        let longContent = String(repeating: "a", count: 500)
        let messages = [MessageData(id: nil, role: "user", content: longContent)]
        let convo = ConversationData(id: "test", title: "Test", messages: messages)

        let truncated = convo.truncated(maxCharsPerMessage: 100, maxMessages: 10)

        XCTAssertEqual(truncated.messages[0].content.count, 103) // 100 + "..."
        XCTAssertTrue(truncated.messages[0].content.hasSuffix("..."))
    }

    func testConversationDataTruncatedPreservesShortMessages() {
        let messages = [
            MessageData(id: nil, role: "user", content: "Short message"),
            MessageData(id: nil, role: "assistant", content: "Another short one")
        ]
        let convo = ConversationData(id: "test", title: "Test", messages: messages)

        let truncated = convo.truncated(maxCharsPerMessage: 100, maxMessages: 10)

        XCTAssertEqual(truncated.messages[0].content, "Short message")
        XCTAssertEqual(truncated.messages[1].content, "Another short one")
        XCTAssertFalse(truncated.wasTruncated, "Should not be marked as truncated if nothing was cut")
    }

    func testConversationDataForSummaryKeepsFirstAndLastOnly() {
        let messages = (0..<5).map { i in
            MessageData(id: nil, role: "user", content: "Message \(i)")
        }
        let convo = ConversationData(id: "test", title: "Test", messages: messages)

        let summary = convo.forSummary()

        XCTAssertEqual(summary.messages.count, 2)
        XCTAssertEqual(summary.messages[0].content, "Message 0")
        XCTAssertEqual(summary.messages[1].content, "Message 4")
        XCTAssertTrue(summary.wasTruncated)
    }

    func testConversationDataForSummaryPreservesShortConversations() {
        let messages = [
            MessageData(id: nil, role: "user", content: "Hello"),
            MessageData(id: nil, role: "assistant", content: "Hi there")
        ]
        let convo = ConversationData(id: "test", title: "Test", messages: messages)

        let summary = convo.forSummary()

        XCTAssertEqual(summary.messages.count, 2)
        XCTAssertFalse(summary.wasTruncated)
    }

    func testConversationDataMetadataOnlyRemovesMessages() {
        let messages = (0..<10).map { i in
            MessageData(id: nil, role: "user", content: "Message \(i)")
        }
        let convo = ConversationData(id: "test", title: "Test Title", messages: messages)

        let metadataOnly = convo.metadataOnly(messageCount: 10, timestamps: (first: Date(), last: Date()))

        XCTAssertEqual(metadataOnly.messages.count, 0)
        XCTAssertEqual(metadataOnly.title, "Test Title")
        XCTAssertEqual(metadataOnly.id, "test")
        XCTAssertTrue(metadataOnly.wasTruncated)
    }

    func testConversationDataEstimatedCharCount() {
        let messages = [
            MessageData(id: nil, role: "user", content: "Hello"),       // 5 chars
            MessageData(id: nil, role: "assistant", content: "World")   // 5 chars
        ]
        let convo = ConversationData(id: "test", title: "Test", messages: messages)  // title = 4 chars

        XCTAssertEqual(convo.estimatedCharCount, 14)  // 4 + 5 + 5
    }

    // MARK: - Capability Detection Tests

    func testCLICapabilitiesIsFullySupportedRequiresAllFlags() {
        // All flags set - should be fully supported
        let fullCaps = CLILLMService.CLICapabilities(
            toolPath: URL(fileURLWithPath: "/usr/local/bin/claude"),
            supportsNoTools: true,
            supportsStdin: true,
            supportsJsonOutput: true,
            supportsPrintMode: true,
            supportsNoSessionPersistence: false
        )
        XCTAssertTrue(fullCaps.isFullySupported)

        // Missing supportsNoTools
        let missingNoTools = CLILLMService.CLICapabilities(
            toolPath: URL(fileURLWithPath: "/usr/local/bin/claude"),
            supportsNoTools: false,
            supportsStdin: true,
            supportsJsonOutput: true,
            supportsPrintMode: true,
            supportsNoSessionPersistence: false
        )
        XCTAssertFalse(missingNoTools.isFullySupported)

        // Missing supportsStdin
        let missingStdin = CLILLMService.CLICapabilities(
            toolPath: URL(fileURLWithPath: "/usr/local/bin/claude"),
            supportsNoTools: true,
            supportsStdin: false,
            supportsJsonOutput: true,
            supportsPrintMode: true,
            supportsNoSessionPersistence: false
        )
        XCTAssertFalse(missingStdin.isFullySupported)

        // Missing supportsJsonOutput
        let missingJson = CLILLMService.CLICapabilities(
            toolPath: URL(fileURLWithPath: "/usr/local/bin/claude"),
            supportsNoTools: true,
            supportsStdin: true,
            supportsJsonOutput: false,
            supportsPrintMode: true,
            supportsNoSessionPersistence: false
        )
        XCTAssertFalse(missingJson.isFullySupported)

        // Missing supportsPrintMode
        let missingPrint = CLILLMService.CLICapabilities(
            toolPath: URL(fileURLWithPath: "/usr/local/bin/claude"),
            supportsNoTools: true,
            supportsStdin: true,
            supportsJsonOutput: true,
            supportsPrintMode: false,
            supportsNoSessionPersistence: false
        )
        XCTAssertFalse(missingPrint.isFullySupported)
    }

    func testCLICapabilitiesUnsupportedStatic() {
        let unsupported = CLILLMService.CLICapabilities.unsupported

        XCTAssertNil(unsupported.toolPath)
        XCTAssertFalse(unsupported.supportsNoTools)
        XCTAssertFalse(unsupported.supportsStdin)
        XCTAssertFalse(unsupported.supportsJsonOutput)
        XCTAssertFalse(unsupported.supportsPrintMode)
        XCTAssertFalse(unsupported.isFullySupported)
    }

    // MARK: - Output Parsing Tests

    func testParseOutputHandlesValidWrapper() throws {
        let validJSON = """
        {
            "result": "{\\"learnings\\": []}",
            "is_error": false
        }
        """
        let data = validJSON.data(using: .utf8)!

        let wrapper = try JSONDecoder().decode(CLILLMService.ClaudeCLIWrapper.self, from: data)

        XCTAssertEqual(wrapper.result, "{\"learnings\": []}")
        XCTAssertFalse(wrapper.is_error ?? false)
        XCTAssertNil(wrapper.error)
    }

    func testParseOutputHandlesErrorWrapper() throws {
        let errorJSON = """
        {
            "is_error": true,
            "error": "Something went wrong"
        }
        """
        let data = errorJSON.data(using: .utf8)!

        let wrapper = try JSONDecoder().decode(CLILLMService.ClaudeCLIWrapper.self, from: data)

        XCTAssertTrue(wrapper.is_error ?? false)
        XCTAssertEqual(wrapper.error, "Something went wrong")
        XCTAssertNil(wrapper.result)
    }

    func testParseOutputHandlesInvalidJSON() {
        let invalidJSON = "not valid json"
        let data = invalidJSON.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(CLILLMService.ClaudeCLIWrapper.self, from: data))
    }

    // MARK: - Error Type Tests

    func testCLIErrorDescriptions() {
        let toolNotFound = CLILLMService.CLIError.toolNotFound(.claudeCode)
        XCTAssertNotNil(toolNotFound.errorDescription)
        XCTAssertTrue(toolNotFound.errorDescription?.contains("not found") ?? false)

        let consentNotGranted = CLILLMService.CLIError.consentNotGranted
        XCTAssertNotNil(consentNotGranted.errorDescription)
        XCTAssertTrue(consentNotGranted.errorDescription?.contains("consent") ?? false)

        let unsupportedVersion = CLILLMService.CLIError.unsupportedCLIVersion(reason: "Missing required flags")
        XCTAssertNotNil(unsupportedVersion.errorDescription)
        XCTAssertTrue(unsupportedVersion.errorDescription?.contains("Missing") ?? false)

        let timeout = CLILLMService.CLIError.timeout(seconds: 300)
        XCTAssertNotNil(timeout.errorDescription)
        XCTAssertTrue(timeout.errorDescription?.contains("timed out") ?? false)

        let payloadTooLarge = CLILLMService.CLIError.payloadTooLarge(bytes: 1000000, maxBytes: 500000)
        XCTAssertNotNil(payloadTooLarge.errorDescription)
        XCTAssertTrue(payloadTooLarge.errorDescription?.contains("1000000") ?? false)
    }

    // MARK: - DetectedTool Tests

    func testDetectedToolProperties() {
        let caps = CLILLMService.CLICapabilities(
            toolPath: URL(fileURLWithPath: "/path/to/claude"),
            supportsNoTools: true,
            supportsStdin: true,
            supportsJsonOutput: true,
            supportsPrintMode: true,
            supportsNoSessionPersistence: false
        )

        let tool = CLILLMService.DetectedTool(tool: .claudeCode, path: "/path/to/claude", capabilities: caps)

        XCTAssertEqual(tool.tool, .claudeCode)
        XCTAssertEqual(tool.path, "/path/to/claude")
        XCTAssertTrue(tool.capabilities.isFullySupported)
    }

    // MARK: - Estimated Size Tests

    func testConversationDataEstimatedJSONSize() {
        let messages = [
            MessageData(id: nil, role: "user", content: String(repeating: "a", count: 1000))
        ]
        let convo = ConversationData(id: "test", title: "Title", messages: messages)

        let estimatedSize = convo.estimatedJSONSize

        // Should be roughly: title (5) + message content (1000) + overhead (50 + 200)
        XCTAssertGreaterThan(estimatedSize, 1000)
        XCTAssertLessThan(estimatedSize, 2000)
    }
}
