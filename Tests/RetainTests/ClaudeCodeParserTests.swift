import XCTest
@testable import Retain

final class ClaudeCodeParserTests: XCTestCase {
    var parser: ClaudeCodeParser!

    override func setUp() {
        parser = ClaudeCodeParser()
    }

    override func tearDown() {
        parser = nil
    }

    // MARK: - Test Data

    private func makeTestJSONL() -> Data {
        let lines = [
            """
            {"uuid":"msg-001","parentUuid":null,"type":"user","sessionId":"session-123","timestamp":"2024-01-15T10:30:00.000Z","cwd":"/Users/test/project","gitBranch":"main","version":"1.0.0","message":{"role":"user","content":"Hello, can you help me with Swift?","id":"msg-id-001"}}
            """,
            """
            {"uuid":"msg-002","parentUuid":"msg-001","type":"assistant","sessionId":"session-123","timestamp":"2024-01-15T10:30:05.000Z","cwd":"/Users/test/project","message":{"role":"assistant","content":"Of course! I'd be happy to help you with Swift. What would you like to know?","model":"claude-3-opus","id":"msg-id-002"}}
            """,
            """
            {"uuid":"msg-003","parentUuid":"msg-002","type":"user","sessionId":"session-123","timestamp":"2024-01-15T10:30:30.000Z","cwd":"/Users/test/project","message":{"role":"user","content":"How do I create an async function?","id":"msg-id-003"}}
            """
        ]
        return lines.joined(separator: "\n").data(using: .utf8)!
    }

    private func makeTestJSONLWithArrayContent() -> Data {
        let line = """
        {"uuid":"msg-001","parentUuid":null,"type":"user","sessionId":"session-456","timestamp":"2024-01-15T10:30:00.000Z","cwd":"/Users/test","message":{"role":"user","content":[{"type":"text","text":"This is array content"}],"id":"msg-id-001"}}
        """
        return line.data(using: .utf8)!
    }

    // MARK: - Parsing Tests

    func testParseBasicJSONL() throws {
        let data = makeTestJSONL()
        guard let (conversation, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(conversation.provider, .claudeCode)
        XCTAssertEqual(conversation.sourceType, .cli)
        XCTAssertEqual(conversation.externalId, "session-123")
        XCTAssertEqual(messages.count, 3)
    }

    func testParseMessageRoles() throws {
        let data = makeTestJSONL()
        guard let (_, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[2].role, .user)
    }

    func testParseMessageContent() throws {
        let data = makeTestJSONL()
        guard let (_, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(messages[0].content, "Hello, can you help me with Swift?")
        XCTAssertTrue(messages[1].content.contains("Of course!"))
        XCTAssertEqual(messages[2].content, "How do I create an async function?")
    }

    func testParseArrayContent() throws {
        let data = makeTestJSONLWithArrayContent()
        guard let (_, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "This is array content")
    }

    func testParseExternalIds() throws {
        let data = makeTestJSONL()
        guard let (_, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(messages[0].externalId, "msg-001")
        XCTAssertEqual(messages[1].externalId, "msg-002")
        XCTAssertEqual(messages[2].externalId, "msg-003")
    }

    func testParseModel() throws {
        let data = makeTestJSONL()
        guard let (_, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertNil(messages[0].model) // User messages don't have model
        XCTAssertEqual(messages[1].model, "claude-3-opus")
    }

    func testParseTimestamps() throws {
        let data = makeTestJSONL()
        guard let (conversation, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        // Check that timestamps are properly parsed
        XCTAssertTrue(messages[0].timestamp < messages[1].timestamp)
        XCTAssertTrue(messages[1].timestamp < messages[2].timestamp)

        // Conversation timestamps should span from first to last message
        XCTAssertEqual(conversation.createdAt, messages.first?.timestamp)
        XCTAssertEqual(conversation.updatedAt, messages.last?.timestamp)
    }

    func testExtractTitleFromFirstMessage() throws {
        let data = makeTestJSONL()
        guard let (conversation, _) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(conversation.title, "Hello, can you help me with Swift?")
    }

    func testExtractTitleTruncation() throws {
        // Create a long first message
        let longMessage = String(repeating: "a", count: 100)
        let line = """
        {"uuid":"msg-001","parentUuid":null,"type":"user","sessionId":"session-789","timestamp":"2024-01-15T10:30:00.000Z","cwd":"/Users/test","message":{"role":"user","content":"\(longMessage)","id":"msg-id-001"}}
        """
        let data = line.data(using: .utf8)!

        guard let (conversation, _) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        // Title should be truncated to 80 chars + "..."
        XCTAssertEqual(conversation.title?.count, 83)
        XCTAssertTrue(conversation.title?.hasSuffix("...") ?? false)
    }

    func testParseProjectPath() throws {
        let data = makeTestJSONL()
        guard let (conversation, _) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(conversation.projectPath, "/Users/test/project")
    }

    // MARK: - Edge Cases

    func testParseEmptyData() throws {
        let data = "".data(using: .utf8)!
        let result = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl"))

        // Empty data should return nil (no messages)
        XCTAssertNil(result, "Empty data should return nil")
    }

    func testParseMalformedLines() throws {
        let lines = [
            """
            {"uuid":"msg-001","parentUuid":null,"type":"user","sessionId":"session-123","timestamp":"2024-01-15T10:30:00.000Z","message":{"role":"user","content":"Valid message content here"}}
            """,
            "this is not valid JSON",
            """
            {"uuid":"msg-002","parentUuid":"msg-001","type":"assistant","sessionId":"session-123","timestamp":"2024-01-15T10:30:05.000Z","message":{"role":"assistant","content":"Another valid message"}}
            """
        ]
        let data = lines.joined(separator: "\n").data(using: .utf8)!

        // Should skip malformed lines and parse valid ones
        guard let (_, messages) = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl")) else {
            XCTFail("Should parse data with messages")
            return
        }

        XCTAssertEqual(messages.count, 2, "Should skip malformed lines")
    }

    func testParseMessageWithEmptyContent() throws {
        let line = """
        {"uuid":"msg-001","parentUuid":null,"type":"user","sessionId":"session-123","timestamp":"2024-01-15T10:30:00.000Z","message":{"role":"user","content":""}}
        """
        let data = line.data(using: .utf8)!

        let result = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl"))

        // Empty content messages result in nil (no valid messages)
        XCTAssertNil(result, "Empty content messages should result in nil")
    }

    func testParseMessageWithNoMessageField() throws {
        let line = """
        {"uuid":"msg-001","parentUuid":null,"type":"user","sessionId":"session-123","timestamp":"2024-01-15T10:30:00.000Z"}
        """
        let data = line.data(using: .utf8)!

        let result = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl"))

        // Lines without message field result in nil
        XCTAssertNil(result, "Lines without message field should result in nil")
    }

    // MARK: - Summary-only Files

    func testParseSummaryOnlyFile() throws {
        let lines = [
            """
            {"type":"summary","summary":"Weekly Report Analysis","leafUuid":"abc123"}
            """,
            """
            {"type":"summary","summary":"Email automation setup","leafUuid":"def456"}
            """
        ]
        let data = lines.joined(separator: "\n").data(using: .utf8)!

        let result = try parser.parseData(data, fileURL: URL(fileURLWithPath: "/test/file.jsonl"))

        // Summary-only files should return nil
        XCTAssertNil(result, "Summary-only files should return nil")
    }

    // MARK: - Discovery Tests

    func testProjectsDirectoryPath() {
        let expectedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        XCTAssertEqual(ClaudeCodeParser.projectsDirectory, expectedPath)
    }
}
